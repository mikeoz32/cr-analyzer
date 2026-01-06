require "../../spec_helper"
require "../../../src/cra/workspace"

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

describe CRA::Workspace do
  it "reindexes dependent files when superclass changes" do
    with_tmpdir do |dir|
      base_path = File.join(dir, "base.cr")
      child_path = File.join(dir, "child.cr")

      File.write(base_path, <<-CRYSTAL)
        class Base
          def greet
          end
        end
      CRYSTAL

      File.write(child_path, <<-CRYSTAL)
        class Child < Base
          def call
            greet
          end
        end
      CRYSTAL

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      child_node = Crystal::Parser.new(File.read(child_path)).parse
      call_node = find_first(child_node) do |n|
        n.is_a?(Crystal::Call) && n.name == "greet"
      end
      call_node.should_not be_nil
      call_node = call_node.not_nil!.as(Crystal::Call)

      def_node = find_first(child_node) do |n|
        n.is_a?(Crystal::Def) && n.name == "call"
      end
      def_node.should_not be_nil
      def_node = def_node.not_nil!.as(Crystal::Def)

      class_node = find_first(child_node) do |n|
        n.is_a?(Crystal::ClassDef) && n.name.full == "Child"
      end
      class_node.should_not be_nil
      class_node = class_node.not_nil!.as(Crystal::ClassDef)

      defs = ws.analyzer.find_definitions(call_node, "Child", def_node, class_node, call_node.location)
      defs.size.should eq(1)
      defs.first.should be_a(CRA::Psi::Method)

      File.write(base_path, <<-CRYSTAL)
        class Base
        end
      CRYSTAL

      reindexed = ws.reindex_file("file://#{base_path}")
      reindexed.should contain("file://#{child_path}")

      defs = ws.analyzer.find_definitions(call_node, "Child", def_node, class_node, call_node.location)
      defs.size.should eq(0)
    end
  end

  it "reindexes dependent files when included module changes" do
    with_tmpdir do |dir|
      module_path = File.join(dir, "mixins.cr")
      child_path = File.join(dir, "child.cr")

      File.write(module_path, <<-CRYSTAL)
        module Mixins
          def greet
          end
        end
      CRYSTAL

      File.write(child_path, <<-CRYSTAL)
        class Child
          include Mixins

          def call
            greet
          end
        end
      CRYSTAL

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      child_node = Crystal::Parser.new(File.read(child_path)).parse
      call_node = find_first(child_node) do |n|
        n.is_a?(Crystal::Call) && n.name == "greet"
      end
      call_node.should_not be_nil
      call_node = call_node.not_nil!.as(Crystal::Call)

      def_node = find_first(child_node) do |n|
        n.is_a?(Crystal::Def) && n.name == "call"
      end
      def_node.should_not be_nil
      def_node = def_node.not_nil!.as(Crystal::Def)

      class_node = find_first(child_node) do |n|
        n.is_a?(Crystal::ClassDef) && n.name.full == "Child"
      end
      class_node.should_not be_nil
      class_node = class_node.not_nil!.as(Crystal::ClassDef)

      defs = ws.analyzer.find_definitions(call_node, "Child", def_node, class_node, call_node.location)
      defs.size.should eq(1)
      defs.first.should be_a(CRA::Psi::Method)

      File.write(module_path, <<-CRYSTAL)
        module Mixins
        end
      CRYSTAL

      reindexed = ws.reindex_file("file://#{module_path}")
      reindexed.should contain("file://#{child_path}")

      defs = ws.analyzer.find_definitions(call_node, "Child", def_node, class_node, call_node.location)
      defs.size.should eq(0)
    end
  end
end
