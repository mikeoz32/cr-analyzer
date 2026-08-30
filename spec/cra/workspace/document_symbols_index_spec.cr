require "../../spec_helper"
require "../../../src/cra/workspace/document_symbols_index"
require "../../../src/cra/workspace/facet_document_symbols_index"
require "../../../src/cra/workspace"

private def symbol_named(symbols : Array(CRA::Types::DocumentSymbol), name : String, kind : CRA::Types::SymbolKind)
  symbols.find { |symbol| symbol.name == name && symbol.kind == kind }
end

private def symbol_contract(symbols : Array(CRA::Types::DocumentSymbol)) : Array(String)
  values = [] of String
  symbols.each do |symbol|
    values << "#{symbol.kind}:#{symbol.name}"
    values.concat(symbol_contract(symbol.children || [] of CRA::Types::DocumentSymbol).map { |child| "  #{child}" })
  end
  values
end

describe CRA::DocumentSymbolsIndex do
  it "builds a hierarchical symbol tree with type members" do
    code = <<-CRYSTAL
      module A
        class B
          def foo
            @bar = 1
          end
        end

        enum Kind
          One
        end
      end

      class C
        def baz
        end
      end
    CRYSTAL

    program = Crystal::Parser.new(code).parse
    index = CRA::DocumentSymbolsIndex.new
    uri = "file:///test.cr"
    index.enter(uri)
    program.accept(index)

    symbols = index[uri]

    mod_a = symbol_named(symbols, "A", CRA::Types::SymbolKind::Module)
    mod_a.should_not be_nil

    mod_children = mod_a.not_nil!.children.not_nil!
    cls_b = symbol_named(mod_children, "B", CRA::Types::SymbolKind::Class)
    cls_b.should_not be_nil

    cls_children = cls_b.not_nil!.children.not_nil!
    method_foo = symbol_named(cls_children, "foo", CRA::Types::SymbolKind::Method)
    method_foo.should_not be_nil

    field_bar = symbol_named(cls_children, "@bar", CRA::Types::SymbolKind::Field)
    field_bar.should_not be_nil

    enum_kind = symbol_named(mod_children, "Kind", CRA::Types::SymbolKind::Enum)
    enum_kind.should_not be_nil
    enum_children = enum_kind.not_nil!.children.not_nil!
    enum_member = symbol_named(enum_children, "One", CRA::Types::SymbolKind::EnumMember)
    enum_member.should_not be_nil

    cls_c = symbol_named(symbols, "C", CRA::Types::SymbolKind::Class)
    cls_c.should_not be_nil
    cls_c_children = cls_c.not_nil!.children.not_nil!
    method_baz = symbol_named(cls_c_children, "baz", CRA::Types::SymbolKind::Method)
    method_baz.should_not be_nil
  end

  it "matches the Crystal symbol contract through Facet syntax queries" do
    code = <<-CRYSTAL
      module A
        class B(T)
          def foo(value : Int32) : String
            @bar : Int32 = value
          end
        end

        enum Kind
          One
        end
      end

      def top_level; end
    CRYSTAL
    uri = "file:///parity.cr"

    crystal = CRA::DocumentSymbolsIndex.new
    crystal.enter(uri)
    Crystal::Parser.new(code).parse.accept(crystal)

    source = Facet::Compiler::Source.new(code, "parity.cr")
    tree = Facet::Compiler::SyntaxTree.new(Facet::Compiler::Parser.new(source).parse_file)
    facet = CRA::FacetDocumentSymbolsIndex.new
    facet.index(uri, tree)

    symbol_contract(facet[uri]).should eq(symbol_contract(crystal[uri]))
  end
end

describe CRA::Workspace do
  it "uses Facet document symbols for an incomplete editor buffer" do
    with_tmpdir do |dir|
      path = File.join(dir, "incomplete.cr")
      File.write(path, "class Broken\nend\n")
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update("class Broken\n  def value(\nend\n")

      document.program.should be_nil
      symbols = workspace.document_symbols(uri)
      symbols.any? { |symbol| symbol.name.starts_with?("Broken") && symbol.kind == CRA::Types::SymbolKind::Class }.should be_true
      symbols.any? { |symbol| symbol.name.starts_with?("value") && symbol.kind == CRA::Types::SymbolKind::Method }.should be_true
    end
  end
end
