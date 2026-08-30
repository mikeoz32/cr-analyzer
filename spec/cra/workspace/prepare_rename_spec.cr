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

private def prepare_rename_request(uri : String, position : CRA::Types::Position) : CRA::Types::PrepareRenameRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/prepareRename",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::PrepareRenameRequest)
end

describe CRA::Workspace do
  it "returns a range for local variable rename" do
    code = <<-CRYSTAL
      def example
        foo = 1
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "prepare_rename_local.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "foo")
      pos = position_for(code, index + 1)
      request = prepare_rename_request(uri, pos)
      range = ws.prepare_rename(request)

      range.should_not be_nil
      expected = range_for(code, index, 3)
      range.not_nil!.start_position.line.should eq(expected.start_position.line)
      range.not_nil!.start_position.character.should eq(expected.start_position.character)
      range.not_nil!.end_position.line.should eq(expected.end_position.line)
      range.not_nil!.end_position.character.should eq(expected.end_position.character)
    end
  end

  it "returns a range for type path segment" do
    code = <<-CRYSTAL
      module Foo
        class Bar
        end
      end

      def call
        Foo::Bar.new
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "prepare_rename_type.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "Foo::Bar")
      pos = position_for(code, index + "Foo::".size + 1)
      request = prepare_rename_request(uri, pos)
      range = ws.prepare_rename(request)

      range.should_not be_nil
      expected = range_for(code, index + "Foo::".size, "Bar".size)
      range.not_nil!.start_position.line.should eq(expected.start_position.line)
      range.not_nil!.start_position.character.should eq(expected.start_position.character)
      range.not_nil!.end_position.line.should eq(expected.end_position.line)
      range.not_nil!.end_position.character.should eq(expected.end_position.character)
    end
  end

  it "uses the Facet name span when Crystal rejects the current buffer" do
    complete_code = <<-CRYSTAL
      def example(value : Int32)
        value
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_prepare_rename.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil

      index = index_for(editing_code, "value", 0)
      range = workspace.prepare_rename(
        prepare_rename_request(uri, position_for(editing_code, index + 1))
      ).not_nil!

      expected = range_for(editing_code, index, "value".size)
      range_key = "#{range.start_position.line}:#{range.start_position.character}-#{range.end_position.line}:#{range.end_position.character}"
      expected_key = "#{expected.start_position.line}:#{expected.start_position.character}-#{expected.end_position.line}:#{expected.end_position.character}"
      range_key.should eq(expected_key)
    end
  end
end
