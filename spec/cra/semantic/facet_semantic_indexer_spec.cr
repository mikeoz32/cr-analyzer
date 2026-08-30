require "../../spec_helper"
require "../../../src/cra/semantic/alayst"

private def method_contract(owner : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum)
  owner.methods.map do |method|
    {
      method.name,
      method.min_arity,
      method.max_arity,
      method.class_method,
      method.return_type,
      method.parameters,
    }
  end.sort_by(&.[0])
end

private def index_facet(index : CRA::Psi::SemanticIndex, uri : String, code : String)
  source = Facet::Compiler::Source.new(code, uri)
  syntax = Facet::Compiler::SyntaxTree.new(Facet::Compiler::Parser.new(source).parse_file)
  index.enter(uri)
  CRA::Psi::FacetSemanticIndexer.new(index).index(syntax)
end

describe CRA::Psi::FacetSemanticIndexer do
  it "matches declaration, method, include, and inheritance contracts" do
    code = <<-CRYSTAL
      # Shared behavior.
      module Shared
        def shared; end
      end

      class Base
        def inherited; end
      end

      class Box(T) < Base
        include Shared

        def initialize(@seed : T)
        end

        def value(item : T, fallback = 1, *rest) : String
        end

        def self.build : Box(T)
        end
      end

      enum Kind
        One
        Two = 2
      end

      alias BoxAlias = Box(Int32)
    CRYSTAL
    uri = "file:///semantic-parity.cr"

    crystal = CRA::Psi::SemanticIndex.new
    crystal.enter(uri)
    crystal.index(Crystal::Parser.new(code).parse)

    source = Facet::Compiler::Source.new(code, "semantic-parity.cr")
    syntax = Facet::Compiler::SyntaxTree.new(Facet::Compiler::Parser.new(source).parse_file)
    facet = CRA::Psi::SemanticIndex.new
    facet.enter(uri)
    CRA::Psi::FacetSemanticIndexer.new(facet).index(syntax)

    facet.type_names_for_file(uri).sort.should eq(crystal.type_names_for_file(uri).sort)
    method_contract(facet.find_module("Shared").not_nil!).should eq(method_contract(crystal.find_module("Shared").not_nil!))
    method_contract(facet.find_class("Base").not_nil!).should eq(method_contract(crystal.find_class("Base").not_nil!))
    method_contract(facet.find_class("Box").not_nil!).should eq(method_contract(crystal.find_class("Box").not_nil!))

    facet.find_enum("Kind").not_nil!.members.map(&.name).should eq(crystal.find_enum("Kind").not_nil!.members.map(&.name))
    facet.type_hierarchy_supertypes("Box").map(&.name).sort.should eq(
      crystal.type_hierarchy_supertypes("Box").map(&.name).sort
    )
    facet.find_module("Shared").not_nil!.doc.should eq("Shared behavior.")
    facet.find_class("Box").not_nil!.methods.find { |method| method.name == "initialize" }.not_nil!.parameters.should eq(["seed"])
  end

  it "keeps qualified include dependencies from other reopen files" do
    index = CRA::Psi::SemanticIndex.new
    index_facet(index, "file:///types.cr", <<-CRYSTAL)
      module Outer
        module Shared
        end

        class Base
        end
      end
    CRYSTAL
    index_facet(index, "file:///box_a.cr", <<-CRYSTAL)
      module Outer
        class Box < Base
          include Shared
        end
      end
    CRYSTAL
    index_facet(index, "file:///box_b.cr", <<-CRYSTAL)
      module Outer
        class Box
          include Shared
        end
      end
    CRYSTAL

    index.type_hierarchy_supertypes("Outer::Box").map(&.name).sort.should eq([
      "Outer::Base",
      "Outer::Shared",
    ])
    index.dependent_types_for(["Outer::Shared"]).should contain("Outer::Box")

    index.remove_file("file:///box_a.cr")

    index.type_hierarchy_supertypes("Outer::Box").map(&.name).should eq(["Outer::Shared"])
    index.dependent_types_for(["Outer::Shared"]).should contain("Outer::Box")
  end

  it "creates semantic namespace shells for explicit type paths" do
    index = CRA::Psi::SemanticIndex.new
    uri = "file:///extension.cr"
    index_facet(index, uri, <<-CRYSTAL)
      class Crystal::ASTNode
        def extension; end
      end
    CRYSTAL

    index.type_names_for_file(uri).sort.should eq(["Crystal", "Crystal::ASTNode"])
    index.find_module("Crystal").should_not be_nil
    index.find_class("Crystal::ASTNode").not_nil!.methods.map(&.name).should contain("extension")
  end

  it "projects tuple and named-tuple return type roles" do
    index = CRA::Psi::SemanticIndex.new
    index_facet(index, "file:///returns.cr", <<-CRYSTAL)
      class Results
        def tuple : {String, Int32}; end
        def named : {value: String}; end
        def optional : {String, Int32}?; end
      end
    CRYSTAL

    methods = index.find_class("Results").not_nil!.methods.to_h { |method| {method.name, method} }
    methods["tuple"].return_type_ref.not_nil!.display.should eq("Tuple(String, Int32)")
    methods["named"].return_type_ref.not_nil!.display.should eq("NamedTuple")
    methods["optional"].return_type_ref.not_nil!.display.should eq("Tuple(String, Int32) | Nil")
  end

  it "indexes only declarations added by a Facet macro expansion" do
    code = <<-CRYSTAL
      macro make_getter(name)
        def {{name.id}}
          @{{name.id}}
        end
      end

      class Box
        def existing
        end

        make_getter :value
      end
    CRYSTAL
    uri = "file:///macro-source.cr"
    virtual_uri = "facet-macro:/macro-source.cr"
    manager = Facet::Compiler::SourceManager.new
    file_id = manager.add(code, "macro-source.cr")
    queries = Facet::Compiler::QueryDb.new(manager)
    original = queries.syntax(file_id)
    expanded = Facet::Compiler::SyntaxTree.new(queries.expand(file_id))

    index = CRA::Psi::SemanticIndex.new
    index.enter(uri)
    indexer = CRA::Psi::FacetSemanticIndexer.new(index)
    indexer.index(original)
    index.enter(virtual_uri)
    indexer.index_generated(expanded, original)

    methods = index.find_class("Box").not_nil!.methods
    methods.count { |method| method.name == "existing" }.should eq(1)
    methods.count { |method| method.name == "value" }.should eq(1)
    methods.find { |method| method.name == "existing" }.not_nil!.file.should eq(uri)
    methods.find { |method| method.name == "value" }.not_nil!.file.should eq(virtual_uri)
  end
end
