require "../../spec_helper"
require "../../../src/cra/workspace"

private def inline_value_request(
  uri : String,
  range : CRA::Types::Range,
) : CRA::Types::InlineValueRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/inlineValue",
    params:  {
      textDocument: {uri: uri},
      range:        {
        start: {line: range.start_position.line, character: range.start_position.character},
        end:   {line: range.end_position.line, character: range.end_position.character},
      },
      context: {
        frameId:         1,
        stoppedLocation: {
          start: {line: range.start_position.line, character: range.start_position.character},
          end:   {line: range.end_position.line, character: range.end_position.character},
        },
      },
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::InlineValueRequest)
end

describe CRA::Workspace do
  it "collects Facet inline values when Crystal rejects the current buffer" do
    complete_code = <<-CRYSTAL
      class Example
        def run(value : Int32)
          local = value
          @field = local
        end
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_inline_values.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil

      range = CRA::Types::Range.new(
        CRA::Types::Position.new(0, 0),
        CRA::Types::Position.new(editing_code.lines.size, 0)
      )
      values = workspace.inline_values(inline_value_request(uri, range))
      names = values.compact_map do |value|
        value.as?(CRA::Types::InlineValueVariableLookup).try(&.variable_name)
      end

      names.should contain("value")
      names.should contain("local")
      names.should contain("@field")
      names.should_not contain("run")
    end
  end
end
