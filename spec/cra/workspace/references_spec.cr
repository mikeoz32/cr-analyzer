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

private def references_request(
  uri : String,
  position : CRA::Types::Position,
  include_declaration : Bool,
) : CRA::Types::ReferencesRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/references",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
      context:      {includeDeclaration: include_declaration},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::ReferencesRequest)
end

describe CRA::Workspace do
  it "finds Facet method references in a Crystal-rejected buffer" do
    complete_code = <<-CRYSTAL
      class Greeter
        def greet
        end

        def call
          greet
          greet
        end
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_method_references.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "greet", 1)
      locations = workspace.find_references(
        references_request(uri, position_for(editing_code, index + 1), true)
      )

      locations.size.should eq(3)
    end
  end

  it "excludes Facet parameter declarations when requested" do
    complete_code = <<-CRYSTAL
      def example(value)
        value
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_local_references.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "value", 1)
      locations = workspace.find_references(
        references_request(uri, position_for(editing_code, index + 1), false)
      )

      locations.size.should eq(1)
      locations.first.range.start_position.line.should eq(1)
    end
  end
end
