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

private def range_key(range : CRA::Types::Range) : String
  "#{range.start_position.line}:#{range.start_position.character}-#{range.end_position.line}:#{range.end_position.character}"
end

private def document_highlight_request(uri : String, position : CRA::Types::Position) : CRA::Types::DocumentHighlightRequest
  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/documentHighlight",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::DocumentHighlightRequest)
end

describe CRA::Workspace do
  it "highlights local variable occurrences in the same def" do
    code = <<-CRYSTAL
      def example
        foo = 1
        foo += 2
        puts foo
      end

      def other
        foo = 3
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "highlight.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "foo", 2)
      pos = position_for(code, index + 1)
      request = document_highlight_request(uri, pos)
      highlights = ws.document_highlights(request)

      highlights.size.should eq(3)
      actual = highlights.map(&.range).map { |range| range_key(range) }.sort
      expected = [
        range_for(code, index_for(code, "foo", 0), 3),
        range_for(code, index_for(code, "foo", 1), 3),
        range_for(code, index_for(code, "foo", 2), 3),
      ].map { |range| range_key(range) }.sort
      actual.should eq(expected)
    end
  end
end
