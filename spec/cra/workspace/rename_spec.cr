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

private def rename_request(uri : String, position : CRA::Types::Position, new_name : String) : CRA::Types::RenameRequest
  payload = {
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/rename",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
      newName:      new_name,
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::RenameRequest)
end

describe CRA::Workspace do
  it "renames local variable usages within a def" do
    code = <<-CRYSTAL
      def example
        foo = 1
        foo += 2
        puts foo
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "rename_local.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "foo", 1)
      pos = position_for(code, index + 1)
      request = rename_request(uri, pos, "bar")
      edit = ws.rename(request)

      edit.should_not be_nil
      changes = edit.not_nil!.changes.not_nil!
      edits = changes[uri]
      edits.size.should eq(3)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("bar") }

      expected = [
        range_for(code, index_for(code, "foo", 0), 3),
        range_for(code, index_for(code, "foo", 1), 3),
        range_for(code, index_for(code, "foo", 2), 3),
      ].map { |range| range_key(range) }.sort
      actual = edits.map(&.range).map { |range| range_key(range) }.sort
      actual.should eq(expected)
    end
  end

  it "renames instance variable usages within a class" do
    code = <<-CRYSTAL
      class Greeter
        def initialize
          @count = 0
        end

        def call
          @count += 1
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "rename_ivar.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "@count", 1)
      pos = position_for(code, index + 2)
      request = rename_request(uri, pos, "@total")
      edit = ws.rename(request)

      edit.should_not be_nil
      changes = edit.not_nil!.changes.not_nil!
      edits = changes[uri]
      edits.size.should eq(2)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("@total") }
    end
  end

  it "renames method definitions and calls in the same workspace" do
    code = <<-CRYSTAL
      class Greeter
        def greet(name)
        end

        def call
          greet("hi")
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "rename_method.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "greet(\"hi\")")
      pos = position_for(code, index + 2)
      request = rename_request(uri, pos, "welcome")
      edit = ws.rename(request)

      edit.should_not be_nil
      changes = edit.not_nil!.changes.not_nil!
      edits = changes[uri]
      edits.size.should eq(2)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("welcome") }
    end
  end

  it "renames type references and definitions" do
    code = <<-CRYSTAL
      class Greeter
      end

      def call
        Greeter.new
        Greeter.new
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "rename_type.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "Greeter.new", 0)
      pos = position_for(code, index + 2)
      request = rename_request(uri, pos, "Welcome")
      edit = ws.rename(request)

      edit.should_not be_nil
      changes = edit.not_nil!.changes.not_nil!
      edits = changes[uri]
      edits.size.should eq(3)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("Welcome") }
    end
  end

  it "renames enum member definitions and references" do
    code = <<-CRYSTAL
      enum Color
        Red
        Green
      end

      def call
        Color::Red
        Color::Red
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "rename_enum_member.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "Red", 0)
      pos = position_for(code, index + 1)
      request = rename_request(uri, pos, "Crimson")
      edit = ws.rename(request)

      edit.should_not be_nil
      changes = edit.not_nil!.changes.not_nil!
      edits = changes[uri]
      edits.size.should eq(3)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("Crimson") }
    end
  end

  it "renames Facet locals when Crystal rejects the current buffer" do
    complete_code = <<-CRYSTAL
      def example
        foo = 1
        foo += 2
        puts foo
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_rename_local.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "foo", 1)
      edit = workspace.rename(rename_request(uri, position_for(editing_code, index + 1), "bar")).not_nil!
      edits = edit.changes.not_nil![uri]

      edits.size.should eq(3)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("bar") }
    end
  end

  it "renames Facet methods when Crystal rejects the current buffer" do
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
      path = File.join(dir, "facet_rename_method.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "greet", 1)
      edit = workspace.rename(rename_request(uri, position_for(editing_code, index + 1), "welcome")).not_nil!
      edits = edit.changes.not_nil![uri]

      edits.size.should eq(2)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("welcome") }
    end
  end

  it "renames Facet types when Crystal rejects the current buffer" do
    complete_code = <<-CRYSTAL
      class Greeter
      end

      def call
        Greeter.new
        Greeter.new
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_rename_type.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "Greeter", 1)
      edit = workspace.rename(rename_request(uri, position_for(editing_code, index + 1), "Welcome")).not_nil!
      edits = edit.changes.not_nil![uri]

      edits.size.should eq(3)
      edits.each { |entry| entry.as(CRA::Types::TextEdit).new_text.should eq("Welcome") }
    end
  end

  it "keeps Facet block-parameter shadowing isolated" do
    code = <<-CRYSTAL
      def example
        value = 1
        [1].each do |value|
          puts value
        end
        puts value
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "facet_rename_shadow.cr")
      File.write(path, code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)

      index = index_for(code, "value", 3)
      edit = workspace.rename(rename_request(uri, position_for(code, index + 1), "result")).not_nil!
      edits = edit.changes.not_nil![uri]

      edits.size.should eq(2)
      actual = edits.map(&.range).map { |range| range_key(range) }.sort
      expected = [
        range_for(code, index_for(code, "value", 0), "value".size),
        range_for(code, index_for(code, "value", 3), "value".size),
      ].map { |range| range_key(range) }.sort
      actual.should eq(expected)
    end
  end
end
