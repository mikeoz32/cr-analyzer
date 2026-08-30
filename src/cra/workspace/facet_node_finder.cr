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
      candidates = [] of Facet::Compiler::SyntaxNode
      @tree.node_at(@byte_offset).try { |node| candidates << node }
      if @byte_offset > 0
        @tree.node_at(@byte_offset - 1).try do |node|
          candidates << node unless candidates.any? { |candidate| candidate.id == node.id }
        end
      end
      @node = candidates.min_by? { |node| {node.span.length, -node.ancestors.size} }
    end

    def context_path : Array(Facet::Compiler::SyntaxNode)
      current = @node
      return [] of Facet::Compiler::SyntaxNode unless current
      current.ancestors.reverse + [current]
    end

    # Returns the semantic construct named at the cursor rather than merely the
    # smallest leaf. Member names resolve to the outer access so consumers keep
    # the receiver; declaration and parameter names resolve to their owner.
    def semantic_node : Facet::Compiler::SyntaxNode?
      path = context_path
      if candidate = path.reverse_each.find do |candidate|
           candidate.receiver && span_at_cursor?(candidate.callee.try(&.name_span))
         end
        return candidate
      end

      if candidate = path.reverse_each.find do |candidate|
           {Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock}.includes?(candidate.kind) &&
           span_at_cursor?(candidate.callee.try(&.name_span))
         end
        return candidate
      end

      path.reverse_each.find do |candidate|
        {
          Facet::Compiler::NodeKind::Def,
          Facet::Compiler::NodeKind::Fun,
          Facet::Compiler::NodeKind::Class,
          Facet::Compiler::NodeKind::Module,
          Facet::Compiler::NodeKind::Struct,
          Facet::Compiler::NodeKind::Enum,
          Facet::Compiler::NodeKind::Lib,
          Facet::Compiler::NodeKind::Alias,
          Facet::Compiler::NodeKind::TypeDef,
          Facet::Compiler::NodeKind::AnnotationDef,
          Facet::Compiler::NodeKind::Param,
          Facet::Compiler::NodeKind::Splat,
          Facet::Compiler::NodeKind::DoubleSplat,
          Facet::Compiler::NodeKind::BlockParam,
          Facet::Compiler::NodeKind::NamedArg,
        }.includes?(candidate.kind) && span_at_cursor?(candidate.name_span)
      end || @node
    end

    def semantic_name_span : Facet::Compiler::Span?
      candidate = semantic_node
      return nil unless candidate
      if candidate.receiver || {Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock}.includes?(candidate.kind)
        candidate.callee.try(&.name_span)
      elsif leaf = @node
        leaf_span = leaf.name_span
        leaf_span && span_at_cursor?(leaf_span) ? leaf_span : candidate.name_span
      else
        candidate.name_span
      end
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

    private def span_at_cursor?(span : Facet::Compiler::Span?) : Bool
      !!(span && @byte_offset >= span.start && @byte_offset <= span.finish)
    end
  end
end
