require "../../spec_helper"
require "../../../src/cra/workspace"

private def index_for(code : String, needle : String, occurrence : Int32 = 0) : Int32
  idx = -1
  (occurrence + 1).times do
    idx = code.index(needle, idx + 1) || raise "needle not found: #{needle}"
  end
  idx
end

private def position_for(code : String, index : Int32) : CRA::Types::Position
  prefix = code[0, index]
  line = prefix.count('\n')
  last_newline = prefix.rindex('\n')
  column = last_newline ? index - last_newline - 1 : index
  CRA::Types::Position.new(line, column)
end

private def declaration_request(uri : String, position : CRA::Types::Position) : CRA::Types::DeclarationRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/declaration",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::DeclarationRequest)
end

private def type_definition_request(uri : String, position : CRA::Types::Position) : CRA::Types::TypeDefinitionRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/typeDefinition",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::TypeDefinitionRequest)
end

private def implementation_request(uri : String, position : CRA::Types::Position) : CRA::Types::ImplementationRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/implementation",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::ImplementationRequest)
end

describe CRA::Workspace do
  it "returns declaration locations for method calls" do
    code = <<-CRYSTAL
      class Greeter
        def greet
        end

        def call
          greet
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "declaration.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      call_index = index_for(code, "greet", 1)
      call_pos = position_for(code, call_index + 1)
      request = declaration_request(uri, call_pos)
      locations = ws.find_declarations(request)

      locations.size.should eq(1)
      start_pos = locations.first.range.start_position
      expected_start = position_for(code, index_for(code, "def greet"))
      start_pos.line.should eq(expected_start.line)
      start_pos.character.should eq(expected_start.character)
    end
  end

  it "returns type definition locations for local variables" do
    code = <<-CRYSTAL
      class User
        def initialize(@name : String)
        end
      end

      def example
        user = User.new("Ada")
        user
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "type_definition.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      use_index = index_for(code, "user", 1)
      use_pos = position_for(code, use_index + 1)
      request = type_definition_request(uri, use_pos)
      locations = ws.find_type_definitions(request)

      locations.size.should eq(1)
      start_pos = locations.first.range.start_position
      expected_start = position_for(code, index_for(code, "class User"))
      start_pos.line.should eq(expected_start.line)
      start_pos.character.should eq(expected_start.character)
    end
  end

  it "returns method implementations from subclasses" do
    code = <<-CRYSTAL
      class Parent
        def greet
        end
      end

      class Child < Parent
        def greet
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "implementation_method.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      base_index = index_for(code, "greet", 0)
      base_pos = position_for(code, base_index + 1)
      request = implementation_request(uri, base_pos)
      locations = ws.find_implementations(request)

      locations.size.should eq(1)
      start_pos = locations.first.range.start_position
      expected_start = position_for(code, index_for(code, "def greet", 1))
      start_pos.line.should eq(expected_start.line)
      start_pos.character.should eq(expected_start.character)
    end
  end

  it "returns type implementations for subclasses" do
    code = <<-CRYSTAL
      class Base
      end

      class Child < Base
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "implementation_type.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      base_index = index_for(code, "Base", 0)
      base_pos = position_for(code, base_index + 1)
      request = implementation_request(uri, base_pos)
      locations = ws.find_implementations(request)

      locations.size.should eq(1)
      start_pos = locations.first.range.start_position
      expected_start = position_for(code, index_for(code, "class Child"))
      start_pos.line.should eq(expected_start.line)
      start_pos.character.should eq(expected_start.character)
    end
  end

  it "uses Facet navigation when Crystal rejects the current buffer" do
    complete_code = <<-CRYSTAL
      class User
        def greet
        end
      end

      def example
        user = User.new
        user.greet
        user
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_navigation.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      method_index = index_for(editing_code, "user.greet") + "user.".size + 2
      declarations = workspace.find_declarations(
        declaration_request(uri, position_for(editing_code, method_index))
      )
      declarations.size.should eq(1)
      declarations.first.range.start_position.line.should eq(
        position_for(editing_code, index_for(editing_code, "def greet")).line
      )

      local_index = index_for(editing_code, "user", 2) + 2
      type_definitions = workspace.find_type_definitions(
        type_definition_request(uri, position_for(editing_code, local_index))
      )
      type_definitions.size.should eq(1)
      type_definitions.first.range.start_position.line.should eq(
        position_for(editing_code, index_for(editing_code, "class User")).line
      )
    end
  end
end
