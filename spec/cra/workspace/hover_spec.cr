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

private def hover_request(uri : String, position : CRA::Types::Position) : CRA::Types::HoverRequest
  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/hover",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::HoverRequest)
end

describe CRA::Workspace do
  it "returns hover signature and documentation" do
    code = <<-CRYSTAL
      class Greeter
        # Says hello.
        def greet(name)
        end
      end

      def call
        greeter = Greeter.new
        greeter.greet("hi")
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "greet(\"hi\")")
      pos = position_for(code, index + "greet".size - 1)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      contents = hover.not_nil!.contents.as_h
      contents["kind"].as_s.should eq("markdown")
      value = contents["value"].as_s
      value.should contain("def Greeter.greet(name)")
      value.should contain("Says hello.")
    end
  end

  it "wraps instance method hover in crystal code fence with dot separator" do
    code = <<-CRYSTAL
      class Foo
        def bar(name : String) : String
          name
        end
      end

      def call
        f = Foo.new
        f.bar("baz")
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_dot.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "bar(\"baz\")")
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("```crystal")
      value.should contain("def Foo.bar(name : String) : String")
      value.should_not contain("Foo#bar")
    end
  end

  it "shows Bool type for local assigned from boolean literal" do
    code = <<-CRYSTAL
      def call
        ipv6_native = false
        ipv6_native
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_bool.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ipv6_native", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ipv6_native : Bool")
    end
  end

  it "shows String type for local assigned from string literal" do
    code = <<-CRYSTAL
      def call
        name = "hello"
        name
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_string.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "name", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("name : String")
    end
  end

  it "shows Int32 type for local assigned from integer literal" do
    code = <<-CRYSTAL
      def call
        count = 42
        count
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_int.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "count", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("count : Int32")
    end
  end

  it "shows inferred type for local assigned from class method call" do
    code = <<-CRYSTAL
      class Resolver
        def self.resolve(name) : String
        end
      end

      def call
        result = Resolver.resolve("foo")
        result
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_class_method.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "result", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("result : String")
    end
  end

  it "shows inferred type for local assigned from class-level [] constructor" do
    code = <<-CRYSTAL
      class Slice(T)
      end

      def call
        ipv4 = Slice[127u8, 0u8, 0u8, 1u8]
        ipv4
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_bracket.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ipv4", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ipv4 : Slice(UInt8)")
    end
  end

  it "shows inferred type for block parameter from method-call-assigned receiver" do
    code = <<-CRYSTAL
      class Resolver
        def self.resolve(names) : Array(String)
        end
      end

      def call
        results = Resolver.resolve(["a", "b"])
        results.each do |item|
          item
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_block_param.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "item", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("item : String")
    end
  end

  it "shows inferred type for block parameter from method block signature" do
    code = <<-CRYSTAL
      class Fetcher
        def self.fetch(& : (String, Int32) -> Nil)
        end
      end

      def call
        Fetcher.fetch do |name, count|
          name
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_block_sig.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "name", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("name : String")
    end
  end

  it "shows inferred type for local assigned from .new" do
    code = <<-CRYSTAL
      class Greeter
        def greet(name)
        end
      end

      def call
        greeter = Greeter.new
        greeter
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_new.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "greeter", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("greeter : Greeter")
    end
  end

  it "shows inferred type for local from generic method return type" do
    code = <<-CRYSTAL
      class Config
        def self.fetch(key : String, default : T) : T forall T
        end
      end

      def call
        env = Config.fetch("MY_ENV", "")
        env
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_generic.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "env", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("env : String")
    end
  end

  it "deduplicates union type when generic resolves to same type" do
    code = <<-CRYSTAL
      class Config
        def self.fetch(key : String, default : T) : String | T forall T
        end
      end

      def call
        env = Config.fetch("MY_ENV", "")
        env
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_union_dedup.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "env", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("env : String")
      value.should_not contain("String | String")
    end
  end

  it "infers Array(UInt8) from array literal with typed elements" do
    code = <<-CRYSTAL
      def call
        bytes = [0u8, 1u8, 2u8]
        bytes
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_array_literal.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "bytes", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("bytes : Array(UInt8)")
    end
  end

  it "shows inferred type from block body when method has no return type" do
    code = <<-CRYSTAL
      class FileReader
        def self.open(path : String, &)
        end
      end

      class IniParser
        def self.parse(source : FileReader) : Hash(String, String)
        end
      end

      def call
        result = FileReader.open("path.ini") { |file| IniParser.parse(file) }
        result
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_block_return.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "result", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("result : Hash(String, String)")
    end
  end

  it "preserves union type when variable is reassigned inside conditional" do
    code = <<-CRYSTAL
      class Env
        def self.fetch(key : String, default : T) : T forall T
        end
      end

      def call
        key = Env.fetch("KEY", [0u8])
        if true
          key = "override"
        end
        key
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_conditional_union.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "key", 3)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("Array(UInt8)")
      value.should contain("String")
    end
  end

  it "narrows type inside is_a? check" do
    code = <<-CRYSTAL
      def call(x : String | Int32)
        if x.is_a?(String)
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_isa.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Int32")
    end
  end

  it "narrows nilable type on truthiness check" do
    code = <<-CRYSTAL
      def call(x : String | Nil)
        if x
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_truthy.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Nil")
    end
  end

  it "narrows type with chained && conditions" do
    code = <<-CRYSTAL
      def call(x : String | Nil, y : Int32 | Nil)
        if x && y
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_and_chain.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Nil")
    end
  end

  it "narrows type in case/when with type pattern" do
    code = <<-CRYSTAL
      def call(x : String | Int32)
        case x
        when String
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_case_when.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Int32")
    end
  end

  it "shows inferred type for block parameter from chained method call" do
    code = <<-CRYSTAL
      class MessageBuilder
        def self.generate(host : String) : Array(String)
        end
      end

      def call
        MessageBuilder.generate("localhost").map do |message|
          message
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_chained_block.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "message", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("message : String")
    end
  end

  it "infers return type of map from block body" do
    code = <<-CRYSTAL
      class Array(T)
        def map(& : T -> U) : Array(U) forall U
        end
      end

      class Builder
        def self.generate(host : String) : Array(String)
        end

        def self.package(msg : String) : Int32
        end
      end

      def call
        packages = Builder.generate("localhost").map { |msg| Builder.package(msg) }
        packages
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_map_return.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "packages", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("packages : Array(Int32)")
    end
  end

  it "narrows type after early return with is_a? check" do
    code = <<-CRYSTAL
      class Slice(T)
      end

      def call(ip : Slice(UInt16) | Slice(UInt8))
        return ip if ip.is_a?(Slice(UInt8))
        ip
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_early_return.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ip", 3)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ip : Slice(UInt16)")
      value.should_not contain("UInt8")
    end
  end

  it "infers Pointer type from .null constructor" do
    code = <<-CRYSTAL
      lib LibC
        struct IfAddrs
          ifa_name : UInt8*
        end
      end

      def call
        ifap = Pointer(LibC::IfAddrs).null
        ifap
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_pointer_null.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ifap", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ifap : Pointer(LibC::IfAddrs)")
    end
  end

  it "infers Proc type from proc literal assignment" do
    code = <<-CRYSTAL
      def call
        handler = ->(x : Int32, y : String) { y }
        handler
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_proc.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "handler", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("handler : Proc(Int32, String, Nil)")
    end
  end

  it "resolves Pointer#current to the pointee type" do
    code = <<-CRYSTAL
      lib LibC
        struct IfAddrs
          ifa_name : UInt8*
        end
      end

      def call
        ptr = Pointer(LibC::IfAddrs).null
        ifa = ptr.current
        ifa
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_pointer_current.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ifa", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ifa : LibC::IfAddrs")
    end
  end

  it "shows type for method parameter on hover" do
    code = <<-CRYSTAL
      class Foo
        def self.generate(ip : StaticArray(UInt8, 4) | StaticArray(UInt8, 16)? = nil)
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_arg.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ip", 0)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ip : StaticArray(UInt8, 4) | StaticArray(UInt8, 16) | Nil")
    end
  end

  it "narrows nilable union type inside if truthiness check" do
    code = <<-CRYSTAL
      class Foo
        def self.generate(ip : StaticArray(UInt8, 4) | StaticArray(UInt8, 16)? = nil)
          if ip
            ip
          end
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_narrow_nilable.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ip", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("StaticArray(UInt8, 4)")
      value.should contain("StaticArray(UInt8, 16)")
      value.should_not contain("Nil")
    end
  end

  it "resolves C struct field types through chained access" do
    code = <<-CRYSTAL
      lib LibC
        type SaFamilyT = UInt8

        struct Sockaddr
          sa_family : SaFamilyT
        end

        struct IfAddrs
          ifa_addr : Sockaddr*
        end
      end

      def call
        ptr = Pointer(LibC::IfAddrs).null
        ifa = ptr.value
        addr = ifa.ifa_addr
        sock = addr.value
        family = sock.sa_family
        family
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_struct_chain.cr")
      File.write(path, code)

      ws = workspace_for(dir)
      uri = "file://#{path}"

      # addr should be Pointer(LibC::Sockaddr) — occ=3 skips "addr" inside Sockaddr/ifa_addr
      index = index_for(code, "addr", 3)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      hover.not_nil!.contents.as_h["value"].as_s.should contain("addr : Pointer(LibC::Sockaddr)")

      # .value on Pointer(Sockaddr) should give Sockaddr
      index = index_for(code, "sock", 1)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      hover.not_nil!.contents.as_h["value"].as_s.should contain("sock : LibC::Sockaddr")

      # .sa_family should resolve to SaFamilyT
      index = index_for(code, "family", 1)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      hover.not_nil!.contents.as_h["value"].as_s.should contain("family : SaFamilyT")
    end
  end

  it "resolves self.class.method to class method" do
    code = <<-CRYSTAL
      class Sender
        def self.send(msg : String) : Bool
        end

        def call
          self.class.send("hello")
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_self_class.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "send", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("def Sender.send(msg : String) : Bool")
    end
  end

  it "infers receiver type for unresolved class method calls" do
    code = <<-CRYSTAL
      def call(io, format)
        ts = Int64.from_io(io, format)
        ts
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_class_fallback.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ts", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ts : Int64")
    end
  end

  it "resolves inherited class method through superclass chain" do
    code = <<-CRYSTAL
      struct Number
      end

      struct Int < Number
        def self.from_io(io, format) : self
        end
      end

      struct Int64 < Int
      end

      def call(io, format)
        ts = Int64.from_io(io, format)
        ts
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_inherited.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "from_io", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("def Int.from_io")

      index = index_for(code, "ts", 1)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      hover.not_nil!.contents.as_h["value"].as_s.should contain("ts : Int64")
    end
  end

  it "infers type from if-expression assignment" do
    code = <<-CRYSTAL
      class Bytes
      end

      def call(family : UInt8)
        ip = if family == 4_u8
               Bytes.new(4)
             elsif family == 6_u8
               Bytes.new(16)
             else
               raise "Unknown"
             end
        ip
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_if_expr.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ip", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ip : Bytes")
    end
  end

  it "infers union type from if-expression with different branch types" do
    code = <<-CRYSTAL
      class Foo
      end
      class Bar
      end

      def call(x : Bool)
        result = if x
                   Foo.new
                 else
                   Bar.new
                 end
        result
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_if_union.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "result", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("Foo")
      value.should contain("Bar")
    end
  end

  it "infers type from uninitialized variable declaration" do
    code = <<-CRYSTAL
      def call
        buffer = uninitialized UInt8[16]
        buffer
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_uninit.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "buffer", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("buffer : StaticArray(UInt8, 16)")
    end
  end

  it "resolves ivar type from getter macro" do
    code = <<-CRYSTAL
      class Bytes
      end

      class Msg
        getter ip : Bytes
        getter family : Symbol

        def initialize(@ip, @family)
        end

        def call
          @ip
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_getter_ivar.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      # Hover on @ip inside method body
      index = index_for(code, "@ip", 1)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("@ip : Bytes")

      # Hover on getter name itself
      index = index_for(code, "ip", 0)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ip : Bytes")

      # Hover on @ip in initialize param (first char)
      index = index_for(code, "@ip", 0)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("Bytes")

      # Hover on last char of @ip param (the 'p') — tests NodeFinder @-prefix fix
      index = index_for(code, "@ip", 0) + 2
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("Bytes")
    end
  end

  it "resolves inherited ivar types from parent getter" do
    code = <<-CRYSTAL
      struct Base
        getter version : Int32
        getter ts : Int64

        def initialize(@version, @ts)
        end
      end

      struct Child < Base
        def call
          @version
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_child_struct.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "@version", 1)
      pos = position_for(code, index)
      hover = ws.hover(hover_request(uri, pos))
      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("@version : Int32")
    end
  end

  it "infers block param type for ClassName.new { |p| }" do
    code = <<-CRYSTAL
      class Conn
        def self.new(&)
          new.tap { |inst| yield inst }
        end
      end

      def call
        Conn.new do |conn|
          conn
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_new_block.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "conn", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("conn : Conn")
    end
  end

  it "infers block param type from yield in method body" do
    code = <<-CRYSTAL
      class Bar
        def self.build(capacity = 64, &)
          builder = new
          yield builder
          builder.to_s
        end
      end

      def call
        Bar.build do |baz|
          baz
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_yield.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "baz", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("baz : Bar")
    end
  end

  it "infers block param type from chained yield through another builder" do
    code = <<-CRYSTAL
      class Baz
        def self.build(capacity = 64, &)
          builder = new
          yield builder
          builder.to_s
        end
      end

      class Foo
        def self.build(capacity = 64, &)
          Baz.build(capacity) do |builder|
            yield builder
          end
        end
      end

      def call
        Foo.build do |bar|
          bar
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_chain_yield.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "bar", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("bar : Baz")
    end
  end

  it "infers block param type across files via pending yield resolution" do
    builder_code = <<-CRYSTAL
      class Foo
        class Builder
          def self.build(capacity = 64, &)
            builder = new
            yield builder
            builder.to_s
          end
        end
      end
    CRYSTAL

    main_code = <<-CRYSTAL
      class Foo
        def self.build(capacity = 64, &)
          Foo::Builder.build(capacity) do |builder|
            yield builder
          end
        end
      end

      def call
        Foo.build do |bar|
          bar
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      File.write(File.join(dir, "builder.cr"), builder_code)
      path = File.join(dir, "main.cr")
      File.write(path, main_code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(main_code, "bar", 1)
      pos = position_for(main_code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("bar : Foo::Builder")
    end
  end

  it "resolves Self block param type to the owner class" do
    code = <<-CRYSTAL
      class Foo
        def self.build(capacity : Int32, & : (self) -> Nil) : self
        end
      end

      def call
        Foo.build(16) do |bar|
          bar
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_self_block.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "bar", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("bar : Foo")
    end
  end

  it "resolves top-level variable types" do
    code = <<-CRYSTAL
      foo = "hello"
      bar = 42
      baz = true
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_toplevel.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "foo", 0)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("foo : String")

      index = index_for(code, "bar", 0)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("bar : Int32")
    end
  end

  it "resolves outer variables and typed params inside proc literals" do
    code = <<-CRYSTAL
      def call
        foo = "hello"
        bar = 42
        cb = ->(x : Int32) {
          foo
          bar
          x
        }
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_proc.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "foo", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("foo : String")

      index = index_for(code, "x", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : Int32")
    end
  end

  it "shows return type for getter with default value" do
    code = <<-CRYSTAL
      class Greeter
        getter name = "world"
        getter count = 0

        def initialize(@name = "world", @count = 0)
        end
      end

      def call
        g = Greeter.new
        g.name
        g.count
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_getter_default.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, ".name")
      pos = position_for(code, index + 1)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("name : String")
      value.should_not contain("def ")

      index = index_for(code, ".count")
      pos = position_for(code, index + 1)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("count : Int32")
      value.should_not contain("def ")
    end
  end

  it "resolves classes defined inside macro-if blocks" do
    code = <<-CRYSTAL
      {% if true %}
        class Greeter
          def greet(name : String) : String
            name
          end
        end
      {% else %}
        class Greeter
          def greet(name : String) : String
            name
          end
        end
      {% end %}

      def call
        g = Greeter.new
        g.greet("foo")
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_macro_if.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "greet", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("Greeter.greet")
      value.should contain(": String")
    end
  end

  it "shows simple getter hover as property type" do
    code = <<-CRYSTAL
      class Item
        getter name : String
        getter count : Int32

        def initialize(@name : String, @count : Int32)
        end
      end

      def call
        item = Item.new("foo", 1)
        item.name
        item.count
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_getter_prop.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "item.name") + "item.".size
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("name : String")
      value.should_not contain("def ")

      index = index_for(code, "item.count") + "item.".size
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("count : Int32")
      value.should_not contain("def ")
    end
  end
end
