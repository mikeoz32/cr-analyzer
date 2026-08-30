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
    id:      1,
    method:  "textDocument/completion",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
      context:      context,
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::CompletionRequest)
end

def labels(items : Array(CRA::Types::CompletionItem)) : Array(String)
  items.map(&.label)
end

describe CRA::Workspace do
  it "completes Facet macro-generated methods without a Crystal AST" do
    box_code = <<-CRYSTAL
      class Box
        make_getter :before
      end
    CRYSTAL
    client_code = <<-CRYSTAL
      class Client
        def test(box : Box)
          box.be
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

      if legacy_box = workspace.analyzer.find_class("Box")
        legacy_box.methods.map(&.name).should_not contain("before")
      end
      generated = workspace.facet_analyzer.find_class("Box").not_nil!.methods.find { |method| method.name == "before" }.not_nil!
      generated.file.not_nil!.should start_with("facet-macro:")

      document = workspace.document(uri).not_nil!
      document.update(editing_client_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)
      index = index_for(editing_client_code, "box.be") + "box.be".size
      items = workspace.complete(completion_request(uri, position_for(editing_client_code, index), "."))

      labels(items).should contain("before")
    end
  end

  it "preserves opaque generic types in Facet macro-generated methods" do
    code = <<-CRYSTAL
      class Item
        def ping
        end
      end

      class Container(T)
        def first : T
        end
      end

      macro make_reader(name, type)
        def {{name.id}} : {{type}}
        end
      end

      class Box
        make_reader items, Container(Item)
      end

      def call(box : Box)
        box.items.first.pi
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "macro_generic.cr")
      File.write(path, code)
      workspace = workspace_for(dir)
      uri = "file://#{path}"
      index = index_for(code, "box.items.first.pi") + "box.items.first.pi".size

      items = workspace.complete(completion_request(uri, position_for(code, index), "."))

      labels(items).should contain("ping")
      generated = workspace.facet_analyzer.find_class("Box").not_nil!.methods.find { |method| method.name == "items" }.not_nil!
      generated.return_type.should eq("Container(Item)")
      generated.file.not_nil!.should start_with("facet-macro:")
    end
  end

  it "indexes declarations generated from Facet user macro blocks" do
    code = <<-CRYSTAL
      macro define_type(name, &block)
        class {{name.id}}
          {{yield}}
        end
      end

      define_type Generated do
        def ping
        end
      end

      def call(value : Generated)
        value.pi
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "macro_block.cr")
      File.write(path, code)
      workspace = workspace_for(dir)
      uri = "file://#{path}"
      index = index_for(code, "value.pi") + "value.pi".size

      items = workspace.complete(completion_request(uri, position_for(code, index), "."))

      labels(items).should contain("ping")
      generated = workspace.facet_analyzer.find_class("Generated").not_nil!
      generated.file.not_nil!.should start_with("facet-macro:")
      generated.methods.map(&.name).should contain("ping")
    end
  end

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "if true") + "if ".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      labels(items).should contain("true")
      labels(items).should_not contain("begin")
    end
  end

  it "uses Facet keyword context when Crystal rejects an incomplete condition" do
    code = "def demo\n  if tr\nend\n"

    with_tmpdir do |dir|
      path = File.join(dir, "incomplete_condition.cr")
      File.write(path, "def demo\nend\n")
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(code)
      document.program.should be_nil

      index = index_for(code, "tr") + "tr".size
      items = workspace.complete(completion_request(uri, position_for(code, index)))

      labels(items).should contain("true")
      labels(items).should_not contain("begin")
    end
  end

  it "reads completion prefixes at LSP UTF-16 positions" do
    code = "def demo\n  value = \"😀\"; trailing\nend\n"

    with_tmpdir do |dir|
      path = File.join(dir, "utf16_completion.cr")
      File.write(path, code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      byte_offset = code.byte_index("trailing").not_nil! + "tr".bytesize
      position = Facet::Compiler::LineIndex.new(
        Facet::Compiler::Source.new(code, path)
      ).position_at(byte_offset)
      request_position = CRA::Types::Position.new(position.line, position.character)

      items = workspace.complete(completion_request(uri, request_position))

      labels(items).should contain("true")
    end
  end

  it "completes Facet-inferred local receivers in a Crystal-rejected buffer" do
    complete_code = <<-CRYSTAL
      class Client
        def fetch; end
      end

      def demo
        client = Client.new
        client.fe
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_local_receiver.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "client.fe") + "client.fe".size
      items = workspace.complete(completion_request(uri, position_for(editing_code, index), "."))

      labels(items).should contain("fetch")
    end
  end

  it "completes named arguments from a Facet call in an incomplete buffer" do
    complete_code = <<-CRYSTAL
      class Client
        def fetch(limit : Int32, label : String); end
      end

      def demo(client : Client)
        client.fetch(limit: 1, label: "ok")
      end
    CRYSTAL
    editing_code = complete_code.sub("limit: 1, label: \"ok\")", "limit: 1, la")

    with_tmpdir do |dir|
      path = File.join(dir, "facet_named_argument.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "limit: 1, la") + "limit: 1, la".size
      items = workspace.complete(completion_request(uri, position_for(editing_code, index)))

      labels(items).should contain("label:")
      labels(items).should_not contain("limit:")
    end
  end

  it "infers chained generic return types through Facet calls" do
    complete_code = <<-CRYSTAL
      class Item
        def ping; end
      end

      class Container(T)
        def value : T; end
      end

      def demo
        container = Container(Item).new
        container.value.pi
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_generic_chain.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "container.value.pi") + "container.value.pi".size
      items = workspace.complete(completion_request(uri, position_for(editing_code, index), "."))

      labels(items).should contain("ping")
    end
  end

  it "completes Facet local names in a Crystal-rejected buffer" do
    complete_code = <<-CRYSTAL
      def demo
        mystery = unknown_call
        mys
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_local_name.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "mys") + "mys".size
      items = workspace.complete(completion_request(uri, position_for(editing_code, index)))

      labels(items).should contain("mystery")
    end
  end

  it "completes Facet instance and class variables in a Crystal-rejected buffer" do
    complete_code = <<-CRYSTAL
      class Box
        def initialize(@bar : Int32)
          @@baz = 1
        end

        def instance_value
          @ba
        end

        def class_value
          @@ba
        end
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_scoped_variables.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      instance_index = index_for(editing_code, "@ba") + "@ba".size
      instance_items = workspace.complete(
        completion_request(uri, position_for(editing_code, instance_index), "@")
      )
      labels(instance_items).should contain("@bar")

      class_index = index_for(editing_code, "@@ba") + "@@ba".size
      class_items = workspace.complete(
        completion_request(uri, position_for(editing_code, class_index), "@")
      )
      labels(class_items).should contain("@@baz")
    end
  end

  it "infers Facet block parameter types in a Crystal-rejected buffer" do
    complete_code = <<-CRYSTAL
      class Item
        def ping
        end
      end

      def demo
        items = Array(Item).new
        items.each do |item|
          item.pi
        end
      end
    CRYSTAL
    editing_code = complete_code + "broken(\n"

    with_tmpdir do |dir|
      path = File.join(dir, "facet_block_parameter.cr")
      File.write(path, complete_code)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update(editing_code)
      document.program.should be_nil
      workspace.reindex_file(uri, document.program)

      index = index_for(editing_code, "item.pi") + "item.pi".size
      items = workspace.complete(completion_request(uri, position_for(editing_code, index), "."))

      labels(items).should contain("ping")
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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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

      ws = workspace_for(dir)

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
