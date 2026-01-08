require "../../spec_helper"
require "../../../src/cra/workspace/document_symbols_index"

private def symbol_named(symbols : Array(CRA::Types::SymbolInformation), name : String, kind : CRA::Types::SymbolKind)
  symbols.find { |symbol| symbol.name == name && symbol.kind == kind }
end

describe CRA::DocumentSymbolsIndex do
  it "tracks containers for nested symbols and resets at top level" do
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
    mod_a.not_nil!.container_name.should be_nil

    cls_b = symbol_named(symbols, "B", CRA::Types::SymbolKind::Class)
    cls_b.should_not be_nil
    cls_b.not_nil!.container_name.should eq("A")

    method_foo = symbol_named(symbols, "foo", CRA::Types::SymbolKind::Method)
    method_foo.should_not be_nil
    method_foo.not_nil!.container_name.should eq("A::B")

    enum_kind = symbol_named(symbols, "Kind", CRA::Types::SymbolKind::Enum)
    enum_kind.should_not be_nil
    enum_kind.not_nil!.container_name.should eq("A")

    cls_c = symbol_named(symbols, "C", CRA::Types::SymbolKind::Class)
    cls_c.should_not be_nil
    cls_c.not_nil!.container_name.should be_nil

    method_baz = symbol_named(symbols, "baz", CRA::Types::SymbolKind::Method)
    method_baz.should_not be_nil
    method_baz.not_nil!.container_name.should eq("C")
  end
end
