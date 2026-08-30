require "../../spec_helper"
require "../../../src/cra/workspace"

private def index_for(code : String, needle : String, occurrence : Int32 = 0) : Int32
  index = -1
  (occurrence + 1).times do
    index = code.index(needle, index + 1) || raise "needle not found: #{needle}"
  end
  index
end

private def position_for(code : String, index : Int32) : CRA::Types::Position
  prefix = code[0, index]
  line = prefix.count('\n')
  last_newline = prefix.rindex('\n')
  column = last_newline ? index - last_newline - 1 : index
  CRA::Types::Position.new(line, column)
end

private def call_hierarchy_prepare_request(
  uri : String,
  position : CRA::Types::Position,
) : CRA::Types::CallHierarchyPrepareRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/prepareCallHierarchy",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
    },
  }.to_json
  CRA::Types::Message.from_json(payload).as(CRA::Types::CallHierarchyPrepareRequest)
end

private def incoming_request(item : CRA::Types::CallHierarchyItem) : CRA::Types::CallHierarchyIncomingCallsRequest
  payload = %({"jsonrpc":"2.0","id":1,"method":"callHierarchy/incomingCalls","params":{"item":#{item.to_json}}})
  CRA::Types::Message.from_json(payload).as(CRA::Types::CallHierarchyIncomingCallsRequest)
end

private def outgoing_request(item : CRA::Types::CallHierarchyItem) : CRA::Types::CallHierarchyOutgoingCallsRequest
  payload = %({"jsonrpc":"2.0","id":1,"method":"callHierarchy/outgoingCalls","params":{"item":#{item.to_json}}})
  CRA::Types::Message.from_json(payload).as(CRA::Types::CallHierarchyOutgoingCallsRequest)
end

describe CRA::Workspace do
  it "builds Facet call hierarchy edges in a Crystal-rejected buffer" do
    complete_code = <<-CRYSTAL
      class Greeter
        def greet
        end

        def call
          greet
        end
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_call_hierarchy.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      greet_call = index_for(editing_code, "greet", 1) + 1
      greet_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_code, greet_call))
      ).first
      incoming = workspace.call_hierarchy_incoming(incoming_request(greet_item))
      incoming.map(&.from.name).should contain("call")
      incoming.first.from_ranges.size.should eq(1)

      caller_name = index_for(editing_code, "call") + 1
      caller_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_code, caller_name))
      ).first
      outgoing = workspace.call_hierarchy_outgoing(outgoing_request(caller_item))
      outgoing.map(&.to.name).should contain("greet")
      outgoing.first.from_ranges.size.should eq(1)
    end
  end

  it "reuses resolved edges and invalidates only after a file revision changes" do
    initial_code = <<-CRYSTAL
      class Greeter
        def greet
        end

        def farewell
        end

        def call
          greet
        end
      end
    CRYSTAL
    editing_code = <<-CRYSTAL
      class Greeter
        def greet
        end

        def farewell
        end

        def call
          farewell
        end
      end
      broken(
    CRYSTAL
    no_call_code = <<-CRYSTAL
      class Greeter
        def greet
        end

        def farewell
        end

        def call
        end
      end
      broken(
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "incremental_call_hierarchy.cr")
      File.write(path, initial_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      graph = workspace.facet_call_graph
      initial_extractions = graph.extraction_count
      initial_resolutions = graph.resolution_count

      caller_name = index_for(initial_code, "call") + 1
      caller_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(initial_code, caller_name))
      ).first
      first_outgoing = workspace.call_hierarchy_outgoing(outgoing_request(caller_item))
      first_outgoing.map(&.to.name).should contain("greet")
      graph.resolution_count.should eq(initial_resolutions + 1)

      workspace.call_hierarchy_outgoing(outgoing_request(caller_item))
      graph.resolution_count.should eq(initial_resolutions + 1)
      graph.extraction_count.should eq(initial_extractions)

      unchanged_document = workspace.document(uri).not_nil!
      workspace.reindex_file(uri, unchanged_document.program)
      graph.extraction_count.should eq(initial_extractions)
      workspace.call_hierarchy_outgoing(outgoing_request(caller_item))
      graph.resolution_count.should eq(initial_resolutions + 1)

      document = unchanged_document
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)
      graph.extraction_count.should eq(initial_extractions + 1)

      updated_caller_name = index_for(editing_code, "call") + 1
      updated_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_code, updated_caller_name))
      ).first
      updated_outgoing = workspace.call_hierarchy_outgoing(outgoing_request(updated_item))
      updated_outgoing.map(&.to.name).should contain("farewell")
      updated_outgoing.map(&.to.name).should_not contain("greet")
      graph.resolution_count.should eq(initial_resolutions + 2)

      document.update(no_call_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)
      empty_caller_name = index_for(no_call_code, "call") + 1
      empty_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(no_call_code, empty_caller_name))
      ).first
      workspace.call_hierarchy_outgoing(outgoing_request(empty_item)).should be_empty
      graph.extraction_count.should eq(initial_extractions + 2)
      graph.resolution_count.should eq(initial_resolutions + 3)
    end
  end

  it "resolves Facet call edges across files from typed receivers" do
    service_code = <<-CRYSTAL
      class Service
        def run
        end
      end
    CRYSTAL
    client_code = <<-CRYSTAL
      class Client
        def invoke(service : Service)
          service.run
        end
      end
    CRYSTAL
    editing_client_code = client_code + "broken(\n"

    with_tmpdir do |dir|
      service_path = File.join(dir, "service.cr")
      client_path = File.join(dir, "client.cr")
      File.write(service_path, service_code)
      File.write(client_path, client_code)
      service_uri = "file://#{service_path}"
      client_uri = "file://#{client_path}"
      workspace = workspace_for(dir)

      client_document = workspace.document(client_uri).not_nil!
      client_document.update(editing_client_code)
      client_document.program.should be_nil
      workspace.reindex_file(client_uri, client_document.program)

      run_name = index_for(service_code, "run") + 1
      run_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(service_uri, position_for(service_code, run_name))
      ).first
      incoming = workspace.call_hierarchy_incoming(incoming_request(run_item))
      incoming.map(&.from.name).should eq(["invoke"])
      incoming.first.from.uri.should eq(client_uri)

      invoke_name = index_for(editing_client_code, "invoke") + 1
      invoke_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(client_uri, position_for(editing_client_code, invoke_name))
      ).first
      outgoing = workspace.call_hierarchy_outgoing(outgoing_request(invoke_item))
      outgoing.map(&.to.name).should eq(["run"])
      outgoing.first.to.uri.should eq(service_uri)
    end
  end

  it "resolves Facet constructor, class-method, and super edges" do
    complete_code = <<-CRYSTAL
      class Base
        def perform
        end
      end

      class Worker < Base
        def initialize
        end

        def perform
          super
        end

        def self.run
        end

        def self.dispatch
          run
        end
      end

      class Driver
        def drive
          Worker.new
          Worker.run
        end
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_special_calls.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      drive_name = index_for(editing_code, "drive") + 1
      drive_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_code, drive_name))
      ).first
      drive_targets = workspace.call_hierarchy_outgoing(outgoing_request(drive_item)).map(&.to.name)
      drive_targets.should contain("initialize")
      drive_targets.should contain("run")

      dispatch_name = index_for(editing_code, "dispatch") + 1
      dispatch_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_code, dispatch_name))
      ).first
      dispatch_targets = workspace.call_hierarchy_outgoing(outgoing_request(dispatch_item))
      dispatch_targets.map(&.to.name).should contain("run")
      dispatch_targets.map(&.to.detail).should contain("Worker")

      worker_perform_name = index_for(editing_code, "perform", 1) + 1
      worker_perform_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_code, worker_perform_name))
      ).first
      super_targets = workspace.call_hierarchy_outgoing(outgoing_request(worker_perform_item))
      super_targets.map(&.to.name).should contain("perform")
      super_targets.map(&.to.detail).should contain("Base")

      base_perform_name = index_for(editing_code, "perform") + 1
      base_perform_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_code, base_perform_name))
      ).first
      super_callers = workspace.call_hierarchy_incoming(incoming_request(base_perform_item))
      super_callers.map(&.from.detail).should contain("Worker")
    end
  end

  it "connects calls to Facet macro-generated methods" do
    box_code = <<-CRYSTAL
      class Box
        make_getter :value
      end
    CRYSTAL
    client_code = <<-CRYSTAL
      class Client
        def invoke(box : Box)
          box.value
        end
      end
    CRYSTAL
    editing_client_code = client_code + "broken(\n"
    macro_code = <<-CRYSTAL
      macro make_getter(name)
        def {{name.id}}
          @{{name.id}}
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      box_path = File.join(dir, "a_box.cr")
      client_path = File.join(dir, "b_client.cr")
      macro_path = File.join(dir, "z_macros.cr")
      File.write(box_path, box_code)
      File.write(client_path, client_code)
      File.write(macro_path, macro_code)
      workspace = workspace_for(dir)
      uri = "file://#{client_path}"
      document = workspace.document(uri).not_nil!
      document.update(editing_client_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      invoke_name = index_for(editing_client_code, "invoke") + 1
      invoke_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_client_code, invoke_name))
      ).first
      outgoing = workspace.call_hierarchy_outgoing(outgoing_request(invoke_item))
      outgoing.map(&.to.name).should contain("value")
      outgoing.find { |call| call.to.name == "value" }.not_nil!.to.uri.should start_with("facet-macro:")

      value_call = index_for(editing_client_code, "box.value") + "box.".size + 1
      value_item = workspace.prepare_call_hierarchy(
        call_hierarchy_prepare_request(uri, position_for(editing_client_code, value_call))
      ).first
      incoming = workspace.call_hierarchy_incoming(incoming_request(value_item))
      incoming.map(&.from.name).should contain("invoke")
    end
  end
end
