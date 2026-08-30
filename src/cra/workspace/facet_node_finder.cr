require "../types"
require "facet/compiler"

module CRA
  # Cursor context over Facet's indexed syntax tree. Positions enter as LSP
  # UTF-16 units and are converted once to Facet byte offsets.
  class FacetNodeFinder
    getter tree : Facet::Compiler::SyntaxTree
    getter node : Facet::Compiler::SyntaxNode?
    getter byte_offset : Int32

    def initialize(@tree : Facet::Compiler::SyntaxTree, position : Types::Position)
      @byte_offset = @tree.offset_at(
        Facet::Compiler::TextPosition.new(position.line, position.character),
        Facet::Compiler::PositionEncoding::Utf16
      )
      @node = @tree.node_at(@byte_offset)
    end

    def context_path : Array(Facet::Compiler::SyntaxNode)
      current = @node
      return [] of Facet::Compiler::SyntaxNode unless current
      current.ancestors.reverse + [current]
    end

    def enclosing_type_name : String?
      names = [] of String
      context_path.each do |candidate|
        next unless {
                      Facet::Compiler::NodeKind::Class,
                      Facet::Compiler::NodeKind::Module,
                      Facet::Compiler::NodeKind::Struct,
                      Facet::Compiler::NodeKind::Enum,
                    }.includes?(candidate.kind)
        name = candidate.name
        next unless name
        if name.includes?("::")
          names = [name]
        else
          names << name
        end
      end
      names.empty? ? nil : names.join("::")
    end

    def enclosing_def : Facet::Compiler::SyntaxNode?
      context_path.reverse_each.find { |candidate| candidate.kind == Facet::Compiler::NodeKind::Def }
    end

    def enclosing_type : Facet::Compiler::SyntaxNode?
      context_path.reverse_each.find do |candidate|
        {
          Facet::Compiler::NodeKind::Class,
          Facet::Compiler::NodeKind::Module,
          Facet::Compiler::NodeKind::Struct,
          Facet::Compiler::NodeKind::Enum,
        }.includes?(candidate.kind)
      end
    end
  end
end
