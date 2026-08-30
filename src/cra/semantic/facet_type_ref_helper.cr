require "facet/compiler"
require "./ast"

module CRA::Psi
  struct FacetSemanticContext
    getter node_path : Array(Facet::Compiler::SyntaxNode)
    getter cursor_offset : Int32
    getter enclosing_type_name : String?
    getter current_file : String?

    def initialize(
      @node_path : Array(Facet::Compiler::SyntaxNode),
      @cursor_offset : Int32,
      @enclosing_type_name : String?,
      @current_file : String? = nil,
    )
    end

    def enclosing_def : Facet::Compiler::SyntaxNode?
      @node_path.reverse_each.find { |node| node.kind == Facet::Compiler::NodeKind::Def }
    end

    def enclosing_type : Facet::Compiler::SyntaxNode?
      @node_path.reverse_each.find do |node|
        {
          Facet::Compiler::NodeKind::Class,
          Facet::Compiler::NodeKind::Module,
          Facet::Compiler::NodeKind::Struct,
          Facet::Compiler::NodeKind::Enum,
        }.includes?(node.kind)
      end
    end
  end
end

module CRA::Psi::FacetTypeRefHelper
  private def type_ref_from_facet(node : Facet::Compiler::SyntaxNode) : CRA::Psi::TypeRef?
    case node.kind
    when Facet::Compiler::NodeKind::Ident, Facet::Compiler::NodeKind::Const,
         Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::LiteralNil
      name = node.kind == Facet::Compiler::NodeKind::LiteralNil ? "Nil" : node.symbol_name
      name ? CRA::Psi::TypeRef.named(name) : nil
    when Facet::Compiler::NodeKind::TypeApply
      name = node.child(0).try(&.symbol_name)
      return nil unless name
      return CRA::Psi::TypeRef.named("NamedTuple") if name == "NamedTuple"
      args = [] of CRA::Psi::TypeRef
      (node.child(1).try(&.children) || [] of Facet::Compiler::SyntaxNode).each do |argument|
        if value = type_ref_from_facet(argument)
          args << value
        end
      end
      CRA::Psi::TypeRef.named(name, args)
    when Facet::Compiler::NodeKind::Tuple
      args = [] of CRA::Psi::TypeRef
      node.children.each do |argument|
        if value = type_ref_from_facet(argument)
          args << value
        end
      end
      CRA::Psi::TypeRef.named("Tuple", args)
    when Facet::Compiler::NodeKind::NamedTuple
      CRA::Psi::TypeRef.named("NamedTuple")
    when Facet::Compiler::NodeKind::Binary
      payload = node.raw.payload_index
      arena = node.tree.ast.arena
      return nil unless payload.in?(0...arena.operators.size)
      return nil unless arena.operator_kind(payload) == Facet::Compiler::TokenKind::Pipe
      parts = [] of CRA::Psi::TypeRef
      node.children.each do |part|
        if value = type_ref_from_facet(part)
          parts << value
        end
      end
      CRA::Psi::TypeRef.union(parts)
    when Facet::Compiler::NodeKind::Splat, Facet::Compiler::NodeKind::DoubleSplat,
         Facet::Compiler::NodeKind::BlockParam
      node.declared_type.try { |value| type_ref_from_facet(value) }
    else
      node.symbol_name.try { |name| CRA::Psi::TypeRef.named(name) }
    end
  end
end
