require "../../spec_helper"
require "../../../src/cra/semantic/alayst"

class ASTFinder < Crystal::Visitor
  getter node : Crystal::ASTNode?

  def initialize(&@predicate : Crystal::ASTNode -> Bool)
  end

  def visit(node : Crystal::ASTNode) : Bool
    return false if @node
    if @predicate.call(node)
      @node = node
      return false
    end
    true
  end
end

def find_first(node : Crystal::ASTNode, &predicate : Crystal::ASTNode -> Bool) : Crystal::ASTNode?
  finder = ASTFinder.new(&predicate)
  node.accept(finder)
  finder.node
end

def build_index(code : String, file : String = "file:///test.cr")
  node = Crystal::Parser.new(code).parse
  index = CRA::Psi::SemanticIndex.new
  index.enter(file)
  index.index(node)
  {index, node}
end

describe CRA::Psi::SemanticIndex do
  it "indexes modules, classes, and methods with locations" do
    code = <<-CRYSTAL
      module A
        class B
          def foo
          end
        end
      end
    CRYSTAL

    index, _node = build_index(code)

    mod = index.find_module("A")
    mod.should_not be_nil
    mod = mod.not_nil!
    mod.location.should_not be_nil
    mod.location.not_nil!.start_line.should eq(0)

    cls = index.find_class("A::B")
    cls.should_not be_nil
    cls = cls.not_nil!
    cls.owner.should eq(mod)
    cls.location.should_not be_nil
    cls.location.not_nil!.start_line.should eq(1)

    method = cls.methods.find { |meth| meth.name == "foo" }
    method.should_not be_nil
    method = method.not_nil!
    method.owner.should eq(cls)
    method.location.should_not be_nil
    method.location.not_nil!.start_line.should eq(2)
  end

  it "indexes nested modules with qualified names" do
    code = <<-CRYSTAL
      module A
        module B
        end
      end
    CRYSTAL

    index, _node = build_index(code)

    mod_a = index.find_module("A")
    mod_a.should_not be_nil
    mod_a = mod_a.not_nil!

    mod_b = index.find_module("A::B")
    mod_b.should_not be_nil
    mod_b = mod_b.not_nil!
    mod_b.owner.should eq(mod_a)
  end

  it "resolves definitions for paths and generics with context" do
    code = <<-CRYSTAL
      module A
        class B
        end

        B
      end

      class Foo
      end

      class Box(T)
      end

      Foo
      Box(Int32)
    CRYSTAL

    index, node = build_index(code)

    path_b = find_first(node) do |n|
      if n.is_a?(Crystal::Path)
        n.full == "B" && n.location.try(&.line_number) == 5
      else
        false
      end
    end
    path_b.should_not be_nil

    defs_b = index.find_definitions(path_b.not_nil!, "A")
    defs_b.size.should eq(1)
    defs_b.first.name.should eq("A::B")

    path_foo = find_first(node) do |n|
      if n.is_a?(Crystal::Path)
        n.full == "Foo" && n.location.try(&.line_number) == 14
      else
        false
      end
    end
    path_foo.should_not be_nil

    defs_foo = index.find_definitions(path_foo.not_nil!)
    defs_foo.size.should eq(1)
    defs_foo.first.name.should eq("Foo")

    generic_box = find_first(node) do |n|
      if n.is_a?(Crystal::Generic)
        if name = n.name.as?(Crystal::Path)
          name.full == "Box" && n.location.try(&.line_number) == 15
        else
          false
        end
      else
        false
      end
    end
    generic_box.should_not be_nil

    defs_box = index.find_definitions(generic_box.not_nil!)
    defs_box.size.should eq(1)
    defs_box.first.name.should eq("Box")
  end

  it "resolves alias definitions" do
    code = <<-CRYSTAL
      alias Text = String
      Text
    CRYSTAL

    index, node = build_index(code)

    path_text = find_first(node) do |n|
      n.is_a?(Crystal::Path) && n.full == "Text" && n.location.try(&.line_number) == 2
    end
    path_text.should_not be_nil

    defs_text = index.find_definitions(path_text.not_nil!)
    defs_text.size.should eq(1)
    defs_text.first.should be_a(CRA::Psi::Alias)
    defs_text.first.name.should eq("Text")
  end

  it "returns all type definitions across files" do
    index = CRA::Psi::SemanticIndex.new

    node_a = Crystal::Parser.new("class Foo\nend\n").parse
    index.enter("file:///a.cr")
    index.index(node_a)

    node_b = Crystal::Parser.new("class Foo\n  def bar; end\nend\n").parse
    index.enter("file:///b.cr")
    index.index(node_b)

    usage = Crystal::Parser.new("Foo").parse.as(Crystal::Path)
    defs = index.find_definitions(usage)

    files = defs.compact_map(&.file).sort
    files.should eq(["file:///a.cr", "file:///b.cr"])
  end

  it "resolves enum types and enum members" do
    code = <<-CRYSTAL
      enum Color
        Red
        Green = 2
      end

      Color
      Color::Green
    CRYSTAL

    index, node = build_index(code)

    path_color = find_first(node) do |n|
      if n.is_a?(Crystal::Path)
        n.full == "Color" && n.location.try(&.line_number) == 6
      else
        false
      end
    end
    path_color.should_not be_nil

    defs_color = index.find_definitions(path_color.not_nil!)
    defs_color.size.should eq(1)
    defs_color.first.should be_a(CRA::Psi::Enum)
    defs_color.first.name.should eq("Color")

    path_green = find_first(node) do |n|
      if n.is_a?(Crystal::Path)
        n.full == "Color::Green" && n.location.try(&.line_number) == 7
      else
        false
      end
    end
    path_green.should_not be_nil

    defs_green = index.find_definitions(path_green.not_nil!)
    defs_green.size.should eq(1)
    defs_green.first.should be_a(CRA::Psi::EnumMember)
    defs_green.first.name.should eq("Green")
  end

  it "resolves relative paths inside nested modules and classes" do
    code = <<-CRYSTAL
      module LF
        module DI
          class BeanFactory
          end

          class Consumer
            def build
              BeanFactory
              DI::BeanFactory
            end
          end
        end
      end
    CRYSTAL

    index, node = build_index(code)

    path_plain = find_first(node) do |n|
      if n.is_a?(Crystal::Path)
        n.full == "BeanFactory" && n.location.try(&.line_number) == 8
      else
        false
      end
    end
    path_plain.should_not be_nil

    defs_plain = index.find_definitions(path_plain.not_nil!, "LF::DI::Consumer")
    defs_plain.size.should eq(1)
    defs_plain.first.name.should eq("LF::DI::BeanFactory")

    path_qualified = find_first(node) do |n|
      if n.is_a?(Crystal::Path)
        n.full == "DI::BeanFactory" && n.location.try(&.line_number) == 9
      else
        false
      end
    end
    path_qualified.should_not be_nil

    defs_qualified = index.find_definitions(path_qualified.not_nil!, "LF::DI::Consumer")
    defs_qualified.size.should eq(1)
    defs_qualified.first.name.should eq("LF::DI::BeanFactory")
  end

  it "resolves method definitions from calls with and without receivers" do
    code = <<-CRYSTAL
      class User
        def greet
        end

        def call
          greet
        end
      end

      class Utils
        def self.parse
        end
      end

      Utils.parse
    CRYSTAL

    index, node = build_index(code)

    call_greet = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "greet" &&
          n.obj.nil? &&
          n.location.try(&.line_number) == 6
      else
        false
      end
    end
    call_greet.should_not be_nil

    defs_greet = index.find_definitions(call_greet.not_nil!, "User")
    defs_greet.size.should eq(1)
    defs_greet.first.should be_a(CRA::Psi::Method)
    defs_greet.first.name.should eq("greet")

    call_parse = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "parse" &&
          n.obj.is_a?(Crystal::Path) &&
          n.location.try(&.line_number) == 15
      else
        false
      end
    end
    call_parse.should_not be_nil

    defs_parse = index.find_definitions(call_parse.not_nil!)
    defs_parse.size.should eq(1)
    defs_parse.first.should be_a(CRA::Psi::Method)
    defs_parse.first.name.should eq("parse")
    defs_parse.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("Utils")
  end

  it "expands built-in getter macro for definitions" do
    code = <<-CRYSTAL
      class User
        getter name
      end

      def use
        user = User.new
        user.name
      end
    CRYSTAL

    index, node = build_index(code)

    call_name = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "name" && n.obj.is_a?(Crystal::Var)
      else
        false
      end
    end
    call_name.should_not be_nil
    call_node = call_name.not_nil!

    def_use = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "use"
    end
    def_use.should_not be_nil
    def_node = def_use.not_nil!.as(Crystal::Def)

    defs = index.find_definitions(call_node, nil, def_node, nil, call_node.location)
    defs.size.should eq(1)
    defs.first.should be_a(CRA::Psi::Method)
    defs.first.name.should eq("name")
    defs.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("User")
  end

  it "expands user-defined macros for definitions" do
    code = <<-CRYSTAL
      macro make_getter(name)
        def {{name}}
        end
      end

      class Box
        make_getter bar
      end

      def use
        box = Box.new
        box.bar
      end
    CRYSTAL

    index, node = build_index(code)

    call_bar = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "bar" && n.obj.is_a?(Crystal::Var)
      else
        false
      end
    end
    call_bar.should_not be_nil
    call_node = call_bar.not_nil!

    def_use = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "use"
    end
    def_use.should_not be_nil
    def_node = def_use.not_nil!.as(Crystal::Def)

    defs = index.find_definitions(call_node, nil, def_node, nil, call_node.location)
    defs.size.should eq(1)
    defs.first.should be_a(CRA::Psi::Method)
    defs.first.name.should eq("bar")
    defs.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("Box")
  end

  it "selects overloads by arity" do
    code = <<-CRYSTAL
      class Overload
        def foo(x)
        end

        def foo(x, y)
        end
      end

      def use
        obj = Overload.new
        obj.foo(1)
        obj.foo(1, 2)
      end
    CRYSTAL

    index, node = build_index(code)

    call_one = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "foo" && n.args.size == 1
      else
        false
      end
    end
    call_one.should_not be_nil
    call_one_node = call_one.not_nil!

    call_two = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "foo" && n.args.size == 2
      else
        false
      end
    end
    call_two.should_not be_nil
    call_two_node = call_two.not_nil!

    def_use = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "use"
    end
    def_use.should_not be_nil
    def_use_node = def_use.not_nil!.as(Crystal::Def)

    defs_one = index.find_definitions(call_one_node, nil, def_use_node, nil, call_one_node.location)
    defs_one.size.should eq(1)
    defs_one.first.should be_a(CRA::Psi::Method)
    defs_one.first.as(CRA::Psi::Method).min_arity.should eq(1)
    defs_one.first.as(CRA::Psi::Method).max_arity.should eq(1)

    defs_two = index.find_definitions(call_two_node, nil, def_use_node, nil, call_two_node.location)
    defs_two.size.should eq(1)
    defs_two.first.should be_a(CRA::Psi::Method)
    defs_two.first.as(CRA::Psi::Method).min_arity.should eq(2)
    defs_two.first.as(CRA::Psi::Method).max_arity.should eq(2)
  end

  it "resolves local variable definitions inside methods" do
    code = <<-CRYSTAL
      def use
        foo = 1
        foo
      end
    CRYSTAL

    index, node = build_index(code)

    var_foo = find_first(node) do |n|
      if n.is_a?(Crystal::Var)
        n.name == "foo" && n.location.try(&.line_number) == 3
      else
        false
      end
    end
    var_foo.should_not be_nil
    var_node = var_foo.not_nil!

    def_use = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "use"
    end
    def_use.should_not be_nil
    def_node = def_use.not_nil!.as(Crystal::Def)

    defs = index.find_definitions(var_node, nil, def_node, nil, var_node.location)
    defs.size.should eq(1)
    defs.first.should be_a(CRA::Psi::LocalVar)
    defs.first.name.should eq("foo")
    defs.first.location.not_nil!.start_line.should eq(1)
  end

  it "resolves instance variable definitions from class or initialize" do
    code = <<-CRYSTAL
      class Foo
        @bar : Int32

        def initialize
          @baz = 1
        end

        def value
          @bar
        end

        def other
          @baz
        end
      end
    CRYSTAL

    index, node = build_index(code)

    class_node = find_first(node) do |n|
      n.is_a?(Crystal::ClassDef) && n.name.full == "Foo"
    end
    class_node.should_not be_nil
    class_def = class_node.not_nil!.as(Crystal::ClassDef)

    def_value = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "value"
    end
    def_value.should_not be_nil
    def_value_node = def_value.not_nil!.as(Crystal::Def)

    def_other = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "other"
    end
    def_other.should_not be_nil
    def_other_node = def_other.not_nil!.as(Crystal::Def)

    ivar_bar = find_first(node) do |n|
      if n.is_a?(Crystal::InstanceVar)
        n.name == "@bar" && n.location.try(&.line_number) == 9
      else
        false
      end
    end
    ivar_bar.should_not be_nil
    ivar_bar_node = ivar_bar.not_nil!.as(Crystal::InstanceVar)

    defs_bar = index.find_definitions(ivar_bar_node, "Foo", def_value_node, class_def, ivar_bar_node.location)
    defs_bar.size.should eq(1)
    defs_bar.first.should be_a(CRA::Psi::InstanceVar)
    defs_bar.first.location.not_nil!.start_line.should eq(1)

    ivar_baz = find_first(node) do |n|
      if n.is_a?(Crystal::InstanceVar)
        n.name == "@baz" && n.location.try(&.line_number) == 13
      else
        false
      end
    end
    ivar_baz.should_not be_nil
    ivar_baz_node = ivar_baz.not_nil!.as(Crystal::InstanceVar)

    defs_baz = index.find_definitions(ivar_baz_node, "Foo", def_other_node, class_def, ivar_baz_node.location)
    defs_baz.size.should eq(1)
    defs_baz.first.should be_a(CRA::Psi::InstanceVar)
    defs_baz.first.location.not_nil!.start_line.should eq(4)
  end

  it "removes file-scoped elements and keeps shared type definitions" do
    code_a = <<-CRYSTAL
      class Foo
        def bar
        end
      end
    CRYSTAL

    code_b = <<-CRYSTAL
      class Foo
        def baz
        end
      end
    CRYSTAL

    index = CRA::Psi::SemanticIndex.new

    node_a = Crystal::Parser.new(code_a).parse
    index.enter("file:///a.cr")
    index.index(node_a)

    node_b = Crystal::Parser.new(code_b).parse
    index.enter("file:///b.cr")
    index.index(node_b)

    foo = index.find_class("Foo")
    foo.should_not be_nil
    foo_methods = foo.not_nil!.methods.map(&.name)
    foo_methods.should contain("bar")
    foo_methods.should contain("baz")

    index.remove_file("file:///b.cr")
    foo = index.find_class("Foo")
    foo.should_not be_nil
    foo_methods = foo.not_nil!.methods.map(&.name)
    foo_methods.should contain("bar")
    foo_methods.should_not contain("baz")

    index.remove_file("file:///a.cr")
    index.find_class("Foo").should be_nil
  end

  it "resolves constructor calls to initialize when no class new matches" do
    code = <<-CRYSTAL
      class Bean
        def self.new
        end

        def initialize(x)
        end
      end

      Bean.new(1)
    CRYSTAL

    index, node = build_index(code)

    call_new = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "new"
      else
        false
      end
    end
    call_new.should_not be_nil
    call_node = call_new.not_nil!

    defs = index.find_definitions(call_node)
    defs.size.should eq(1)
    defs.first.should be_a(CRA::Psi::Method)
    defs.first.name.should eq("initialize")
  end

  it "resolves constructor calls to class new when it matches" do
    code = <<-CRYSTAL
      class Bean
        def self.new(x)
        end

        def initialize(x)
        end
      end

      Bean.new(1)
    CRYSTAL

    index, node = build_index(code)

    call_new = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "new"
      else
        false
      end
    end
    call_new.should_not be_nil
    call_node = call_new.not_nil!

    defs = index.find_definitions(call_node)
    defs.size.should eq(1)
    defs.first.should be_a(CRA::Psi::Method)
    defs.first.name.should eq("new")
    defs.first.as(CRA::Psi::Method).class_method.should be_true
  end

  it "resolves method definitions from cast receivers" do
    code = <<-CRYSTAL
      class StringBuffer
        def string_at(index)
        end
      end

      def read(buffer, index)
        buffer.as(StringBuffer).string_at(index)
      end
    CRYSTAL

    index, node = build_index(code)

    call_string_at = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "string_at"
      else
        false
      end
    end
    call_string_at.should_not be_nil
    call_node = call_string_at.not_nil!

    defs_string_at = index.find_definitions(call_node)
    defs_string_at.size.should eq(1)
    defs_string_at.first.should be_a(CRA::Psi::Method)
    defs_string_at.first.name.should eq("string_at")
    defs_string_at.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("StringBuffer")
  end

  it "resolves method definitions from local assignments" do
    code = <<-CRYSTAL
      class StringBuffer
        def string_at(index)
        end
      end

      def read(index)
        buffer = StringBuffer.new
        buffer.string_at(index)
      end
    CRYSTAL

    index, node = build_index(code)

    call_string_at = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "string_at"
      else
        false
      end
    end
    call_string_at.should_not be_nil
    call_node = call_string_at.not_nil!

    def_read = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "read"
    end
    def_read.should_not be_nil
    def_node = def_read.not_nil!.as(Crystal::Def)

    defs_string_at = index.find_definitions(call_node, nil, def_node, nil, call_node.location)
    defs_string_at.size.should eq(1)
    defs_string_at.first.should be_a(CRA::Psi::Method)
    defs_string_at.first.name.should eq("string_at")
    defs_string_at.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("StringBuffer")
  end

  it "resolves method definitions from ivars initialized in initialize" do
    code = <<-CRYSTAL
      class StringBuffer
        def string_at(index)
        end
      end

      class Reader
        def initialize
          @buffer = StringBuffer.new
        end

        def read(index)
          @buffer.string_at(index)
        end
      end
    CRYSTAL

    index, node = build_index(code)

    call_string_at = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "string_at"
      else
        false
      end
    end
    call_string_at.should_not be_nil
    call_node = call_string_at.not_nil!

    def_read = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "read"
    end
    def_read.should_not be_nil
    def_node = def_read.not_nil!.as(Crystal::Def)

    class_reader = find_first(node) do |n|
      n.is_a?(Crystal::ClassDef) && n.name.full == "Reader"
    end
    class_reader.should_not be_nil
    class_node = class_reader.not_nil!.as(Crystal::ClassDef)

    defs_string_at = index.find_definitions(call_node, "Reader", def_node, class_node, call_node.location)
    defs_string_at.size.should eq(1)
    defs_string_at.first.should be_a(CRA::Psi::Method)
    defs_string_at.first.name.should eq("string_at")
    defs_string_at.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("StringBuffer")
  end

  it "resolves instance methods from superclass" do
    code = <<-CRYSTAL
      class Base
        def greet
        end
      end

      class Child < Base
        def call
          greet
        end
      end
    CRYSTAL

    index, node = build_index(code)

    call_greet = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "greet" && n.obj.nil?
      else
        false
      end
    end
    call_greet.should_not be_nil
    call_node = call_greet.not_nil!

    def_call = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "call"
    end
    def_call.should_not be_nil
    def_node = def_call.not_nil!.as(Crystal::Def)

    class_child = find_first(node) do |n|
      n.is_a?(Crystal::ClassDef) && n.name.full == "Child"
    end
    class_child.should_not be_nil
    class_node = class_child.not_nil!.as(Crystal::ClassDef)

    defs_greet = index.find_definitions(call_node, "Child", def_node, class_node, call_node.location)
    defs_greet.size.should eq(1)
    defs_greet.first.should be_a(CRA::Psi::Method)
    defs_greet.first.name.should eq("greet")
    defs_greet.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("Base")
  end

  it "resolves instance methods from included modules" do
    code = <<-CRYSTAL
      module Speakable
        def ping
        end
      end

      class Host
        include Speakable
      end

      def use
        host = Host.new
        host.ping
      end
    CRYSTAL

    index, node = build_index(code)

    call_ping = find_first(node) do |n|
      if n.is_a?(Crystal::Call)
        n.name == "ping" && n.obj.is_a?(Crystal::Var)
      else
        false
      end
    end
    call_ping.should_not be_nil
    call_node = call_ping.not_nil!

    def_use = find_first(node) do |n|
      n.is_a?(Crystal::Def) && n.name == "use"
    end
    def_use.should_not be_nil
    def_node = def_use.not_nil!.as(Crystal::Def)

    defs_ping = index.find_definitions(call_node, nil, def_node, nil, call_node.location)
    defs_ping.size.should eq(1)
    defs_ping.first.should be_a(CRA::Psi::Method)
    defs_ping.first.name.should eq("ping")
    defs_ping.first.as(CRA::Psi::Method).owner.not_nil!.name.should eq("Speakable")
  end

  it "clears owner stack on enter" do
    index = CRA::Psi::SemanticIndex.new

    code_one = <<-CRYSTAL
      module A
        class B
        end
      end
    CRYSTAL

    index.enter("file:///one.cr")
    index.index(Crystal::Parser.new(code_one).parse)

    code_two = <<-CRYSTAL
      class C
      end
    CRYSTAL

    index.enter("file:///two.cr")
    index.index(Crystal::Parser.new(code_two).parse)

    mod_a = index.find_module("A").not_nil!
    mod_a.classes.any? { |cls| cls.name == "C" }.should be_false

    cls_c = index.find_class("C")
    cls_c.should_not be_nil
  end
end
