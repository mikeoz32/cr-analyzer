require "../../spec_helper"
require "../../../src/cra/workspace"

def index_for(code : String, needle : String, occurrence : Int32 = 0) : Int32
  idx = -1
  (occurrence + 1).times do
    idx = code.index(needle, idx + 1) || raise "needle not found: #{needle}"
  end
  idx
end

def position_for(code : String, index : Int32) : CRA::Types::Position
  prefix = code[0, index]
  line = prefix.count('\n')
  last_newline = prefix.rindex('\n')
  column = last_newline ? index - last_newline - 1 : index
  CRA::Types::Position.new(line, column)
end

def completion_request(uri : String, position : CRA::Types::Position, trigger_char : String? = nil) : CRA::Types::CompletionRequest
  context = if trigger_char
              {triggerKind: 2, triggerCharacter: trigger_char}
            else
              {triggerKind: 1}
            end

  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/completion",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
      context: context,
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::CompletionRequest)
end

def labels(items : Array(CRA::Types::CompletionItem)) : Array(String)
  items.map(&.label)
end

describe CRA::Workspace do
  it "completes instance methods on typed locals" do
    code = <<-CRYSTAL
      class Greeter
        def greet
        end

        def grab
        end
      end

      def call
        greeter = Greeter.new
        greeter.gr
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "main.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "greeter.gr") + "greeter.gr".size
      pos = position_for(code, index)
      request = completion_request(uri, pos, ".")
      items = ws.complete(request)

      labels(items).should contain("greet")
      labels(items).should contain("grab")
    end
  end

  it "completes instance variables" do
    code = <<-CRYSTAL
      class Box
        def initialize
          @bar = 1
          @baz = 2
        end

        def value
          @ba
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "box.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "@ba") + "@ba".size
      pos = position_for(code, index)
      request = completion_request(uri, pos, "@")
      items = ws.complete(request)

      labels(items).should contain("@bar")
      labels(items).should contain("@baz")
    end
  end

  it "completes keywords in method bodies" do
    code = <<-CRYSTAL
      def demo
        ret
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "demo.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "ret") + "ret".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("return")
    end
  end

  it "suggests def in class bodies" do
    code = <<-CRYSTAL
      class Box
        de
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "class_body.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "de") + "de".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("def")
    end
  end

  it "suggests else and elsif inside if blocks" do
    code = <<-CRYSTAL
      def demo
        if cond
          el
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "if_body.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "el") + "el".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("else")
      labels(items).should contain("elsif")
    end
  end

  it "suggests when inside case statements" do
    code = <<-CRYSTAL
      def demo
        case value
          when 1
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "case_body.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "when") + "wh".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("when")
    end
  end

  it "completes global types from nested scopes" do
    code = <<-CRYSTAL
      class Array
      end

      module Wrapper
        class Demo
          def call
            Ar
          end
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "demo.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "Ar", 1) + "Ar".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("Array")
    end
  end

  it "limits keywords inside if conditions" do
    code = <<-CRYSTAL
      def demo
        if true
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "if_condition.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "if true") + "if ".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("true")
      labels(items).should_not contain("begin")
    end
  end

  it "completes alias types" do
    code = <<-CRYSTAL
      alias Token = String

      def call
        Tok
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "alias.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "Tok") + "Tok".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("Token")
    end
  end

  it "completes class methods on generic types" do
    code = <<-CRYSTAL
      class Array(T)
        def self.named
        end
      end

      def call
        Array(Int32).na
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "generic.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "Array(Int32).na") + "Array(Int32).na".size
      pos = position_for(code, index)
      request = completion_request(uri, pos, ".")
      items = ws.complete(request)

      labels(items).should contain("named")
    end
  end

  it "completes chained calls with generic return types" do
    code = <<-CRYSTAL
      class Item
        def ping
        end
      end

      class Container(T)
        def initialize(@value : T)
        end

        def value : T
        end
      end

      def call
        container = Container(Item).new(Item.new)
        container.value.p
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "container.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "container.value.p") + "container.value.p".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("ping")
    end
  end

  it "completes methods on indexed generic values" do
    code = <<-CRYSTAL
      class BufferIndex
        def clear
        end
      end

      class Container(T)
        def initialize(@items : Array(T))
        end

        def [](index : Int32) : T
        end
      end

      def call
        container = Container(BufferIndex).new(Array(BufferIndex).new)
        container[1].cl
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "buffer_index.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "container[1].") + "container[1].".size
      pos = position_for(code, index)
      request = completion_request(uri, pos, ".")
      items = ws.complete(request)

      labels(items).should contain("clear")
    end
  end

  it "prefers element type for array index access" do
    code = <<-CRYSTAL
      class BufferIndex
        def clear
        end
      end

      class Array(T)
        def [](range : Range(Int32, Int32)) : Array(T)
        end

        def [](index : Int32) : T
        end
      end

      def call
        items = Array(BufferIndex).new
        items[1].cl
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "array_index.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "items[1].") + "items[1].".size
      pos = position_for(code, index)
      request = completion_request(uri, pos, ".")
      items = ws.complete(request)

      labels(items).should contain("clear")
    end
  end

  it "completes require paths from src" do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src/foo"))
      File.write(File.join(dir, "src/foo/bar.cr"), "")
      File.write(File.join(dir, "src/foo/baz.cr"), "")

      code = <<-CRYSTAL
        require "foo/ba"
      CRYSTAL

      path = File.join(dir, "main.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "foo/ba") + "foo/ba".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("foo/bar")
      labels(items).should contain("foo/baz")
    end
  end
end
