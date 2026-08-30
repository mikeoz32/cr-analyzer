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

private def range_for(code : String, index : Int32, length : Int32) : CRA::Types::Range
  start_pos = position_for(code, index)
  end_pos = position_for(code, index + length)
  CRA::Types::Range.new(start_position: start_pos, end_position: end_pos)
end

private def selection_range_request(uri : String, position : CRA::Types::Position) : CRA::Types::SelectionRangeRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/selectionRange",
    params:  {
      textDocument: {uri: uri},
      positions:    [{line: position.line, character: position.character}],
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::SelectionRangeRequest)
end

describe CRA::Workspace do
  it "returns selection range chain for the node under cursor" do
    code = <<-CRYSTAL
      def example
        value = "hi".upcase
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "selection_range.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "upcase")
      pos = position_for(code, index + 2)
      request = selection_range_request(uri, pos)
      ranges = ws.selection_ranges(request)

      ranges.size.should eq(1)
      selection = ranges.first
      expected = range_for(code, index, "upcase".size)
      selection.range.start_position.line.should eq(expected.start_position.line)
      selection.range.start_position.character.should eq(expected.start_position.character)
      selection.range.end_position.line.should eq(expected.end_position.line)
      selection.range.end_position.character.should eq(expected.end_position.character)
      selection.parent.should_not be_nil
    end
  end

  it "keeps selection ranges available when Crystal cannot parse the buffer" do
    code = "class Broken\n  def value(\nend\n"
    with_tmpdir do |dir|
      path = File.join(dir, "incomplete_selection.cr")
      File.write(path, "class Broken\nend\n")
      uri = "file://#{path}"
      ws = workspace_for(dir)
      document = ws.document(uri).not_nil!
      document.update(code)

      index = index_for(code, "value")
      position = position_for(code, index + 2)
      finder = document.facet_node_context(position).not_nil!
      finder.enclosing_type_name.should eq("Broken")

      ranges = ws.selection_ranges(selection_range_request(uri, position))
      ranges.size.should eq(1)
      ranges.first.range.should_not be_nil
      ranges.first.parent.should_not be_nil
    end
  end
end
