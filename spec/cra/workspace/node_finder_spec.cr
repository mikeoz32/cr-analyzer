require "../../spec_helper"
require "../../../src/cra/workspace"

CODE = <<-CRYSTAL
  module Outer
    module Inner
      class Foo
        def bar(x)
          @ivar = x
          baz = Foo.new
          self.bar(x)
          Foo.bar(x)
          EnumType::Value
        end
      end

      enum EnumType
        Value
      end

      module Deep::Nest
        class Widget
          def ping
            Widget.new
          end
        end
      end
    end
  end
CRYSTAL

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

def find_finder(code : String, needle : String, occurrence : Int32 = 0, offset : Int32 = 0) : CRA::NodeFinder
  idx = index_for(code, needle, occurrence) + offset
  finder = CRA::NodeFinder.new(position_for(code, idx))
  program = Crystal::Parser.new(code).parse
  program.accept(finder)
  finder
end

describe CRA::NodeFinder do
  it "finds def names via name_location and qualifies context" do
    finder = find_finder(CODE, "def bar", 0, 4)
    finder.node.should be_a(Crystal::Def)
    finder.enclosing_type_name.should eq("Outer::Inner::Foo")
  end

  it "finds calls on implicit receivers" do
    finder = find_finder(CODE, "self.bar", 0, "self.".size)
    finder.node.should be_a(Crystal::Call)
    finder.node.as(Crystal::Call).name.should eq("bar")
    finder.enclosing_type_name.should eq("Outer::Inner::Foo")
  end

  it "finds calls on constant receivers" do
    finder = find_finder(CODE, "Foo.bar", 0, "Foo.".size)
    finder.node.should be_a(Crystal::Call)
    finder.node.as(Crystal::Call).name.should eq("bar")
  end

  it "finds constant paths" do
    finder = find_finder(CODE, "EnumType::Value")
    finder.node.should be_a(Crystal::Path)
    finder.node.as(Crystal::Path).full.should eq("EnumType::Value")
  end

  it "resets context for module paths with ::" do
    finder = find_finder(CODE, "Widget.new", 0, "Widget.".size)
    finder.node.should be_a(Crystal::Call)
    finder.enclosing_type_name.should eq("Deep::Nest::Widget")
  end

  it "returns enum context for members" do
    finder = find_finder(CODE, "Value", 1)
    finder.node.should_not be_nil
    finder.enclosing_type_name.should eq("Outer::Inner::EnumType")
  end

  it "prefers inner nodes inside case/when bodies" do
    code = <<-CRYSTAL
      case token
      when "string"
        buffer.as(StringBuffer).string_at(index) || ""
      end
    CRYSTAL

    finder = find_finder(code, "StringBuffer", 0, 2)
    finder.node.should be_a(Crystal::Path)
    finder.node.as(Crystal::Path).names.join("::").should eq("StringBuffer")

    finder_call = find_finder(code, "string_at", 0, 1)
    finder_call.node.should be_a(Crystal::Call)
    finder_call.node.as(Crystal::Call).name.should eq("string_at")
  end

  it "tracks the previous node when the cursor is after a generic" do
    code = "Array(Int32)\n"
    finder = find_finder(code, "Array(Int32)", 0, "Array(Int32)".size + 1)
    finder.node.should be_nil
    finder.previous_node.should be_a(Crystal::Generic)
    finder.previous_node.as(Crystal::Generic).name.to_s.should eq("Array")
  end
end
