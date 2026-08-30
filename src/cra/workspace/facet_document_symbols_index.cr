require "../types"
require "facet/compiler"

module CRA
  # Document-symbol projection backed directly by Facet's native syntax query
  # API. It runs in shadow mode for valid Crystal ASTs and becomes the fallback
  # when Crystal::Parser cannot produce a program for an incomplete edit.
  class FacetDocumentSymbolsIndex
    getter symbols : Hash(String, Array(Types::DocumentSymbol))

    def initialize
      @symbols = {} of String => Array(Types::DocumentSymbol)
      @field_names = {} of String => Set(String)
    end

    def index(uri : String, tree : Facet::Compiler::SyntaxTree) : Array(Types::DocumentSymbol)
      roots = [] of Types::DocumentSymbol
      @symbols[uri] = roots
      @field_names.clear
      collect(tree.root, roots, nil, nil, tree)
      roots
    end

    def [](uri : String) : Array(Types::DocumentSymbol)
      @symbols[uri]? || [] of Types::DocumentSymbol
    end

    def symbol_informations(uri : String) : Array(Types::SymbolInformation)
      flat = [] of Types::SymbolInformation
      self[uri].each { |symbol| flatten_symbol(symbol, flat, nil, uri) }
      flat
    end

    private def collect(
      node : Facet::Compiler::SyntaxNode,
      output : Array(Types::DocumentSymbol),
      type_symbol : Types::DocumentSymbol?,
      container : String?,
      tree : Facet::Compiler::SyntaxTree,
    ) : Nil
      if kind = declaration_kind(node.kind, !type_symbol.nil?)
        name = node.name
        if name
          symbol = document_symbol(node, name, kind, declaration_detail(node), tree)
          output << symbol
          child_output = symbol.children ||= [] of Types::DocumentSymbol
          next_type = type_declaration?(node.kind) ? symbol : type_symbol
          next_container = type_declaration?(node.kind) ? qualify(container, name) : container

          add_enum_members(node, child_output, tree) if node.kind == Facet::Compiler::NodeKind::Enum
          node.body.try { |body| collect(body, child_output, next_type, next_container, tree) }
          return
        end
      end

      if type_symbol && container
        case node.kind
        when Facet::Compiler::NodeKind::VarDecl, Facet::Compiler::NodeKind::Assign
          record_field(node, type_symbol, container, tree)
        end
      end

      # Macro templates are compile-time source and do not appear in the
      # existing document-symbol contract.
      return if node.kind == Facet::Compiler::NodeKind::MacroDef
      node.children.each { |child| collect(child, output, type_symbol, container, tree) }
    end

    private def declaration_kind(kind : Facet::Compiler::NodeKind, inside_type : Bool) : Types::SymbolKind?
      case kind
      when Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Lib
        Types::SymbolKind::Module
      when Facet::Compiler::NodeKind::Class
        Types::SymbolKind::Class
      when Facet::Compiler::NodeKind::Struct
        Types::SymbolKind::Struct
      when Facet::Compiler::NodeKind::Enum
        Types::SymbolKind::Enum
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
        inside_type ? Types::SymbolKind::Method : Types::SymbolKind::Function
      when Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef
        Types::SymbolKind::Class
      when Facet::Compiler::NodeKind::AnnotationDef
        Types::SymbolKind::Interface
      else
        nil
      end
    end

    private def type_declaration?(kind : Facet::Compiler::NodeKind) : Bool
      {
        Facet::Compiler::NodeKind::Module,
        Facet::Compiler::NodeKind::Class,
        Facet::Compiler::NodeKind::Struct,
        Facet::Compiler::NodeKind::Enum,
        Facet::Compiler::NodeKind::Lib,
      }.includes?(kind)
    end

    private def document_symbol(
      node : Facet::Compiler::SyntaxNode,
      name : String,
      kind : Types::SymbolKind,
      detail : String?,
      tree : Facet::Compiler::SyntaxTree,
    ) : Types::DocumentSymbol
      Types::DocumentSymbol.new(
        name: name,
        kind: kind,
        range: range_for(node.span, tree),
        selection_range: range_for(node.name_span || node.span, tree),
        detail: detail
      )
    end

    private def declaration_detail(node : Facet::Compiler::SyntaxNode) : String?
      case node.kind
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
        args = node.parameters.map(&.text).join(", ")
        detail = args.empty? ? "" : "(#{args})"
        if return_type = node.return_type
          detail = detail.empty? ? ": #{return_type.text}" : "#{detail} : #{return_type.text}"
        end
        detail.empty? ? nil : detail
      when Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Struct
        name = node.name_node
        return nil unless name && name.kind == Facet::Compiler::NodeKind::TypeApply
        args = name.child(1).try(&.children) || [] of Facet::Compiler::SyntaxNode
        args.empty? ? nil : "(#{args.map(&.text).join(", ")})"
      else
        nil
      end
    end

    private def record_field(
      node : Facet::Compiler::SyntaxNode,
      type_symbol : Types::DocumentSymbol,
      container : String,
      tree : Facet::Compiler::SyntaxTree,
    ) : Nil
      target = node.target
      return unless target
      return unless {
                      Facet::Compiler::NodeKind::InstanceVar,
                      Facet::Compiler::NodeKind::ClassVar,
                    }.includes?(target.kind)
      name = target.symbol_name
      return unless name && !name.empty?
      names = @field_names[container] ||= Set(String).new
      return if names.includes?(name)
      names << name

      detail = node.kind == Facet::Compiler::NodeKind::VarDecl ? node.declared_type.try(&.text) : nil
      field = document_symbol(target, name, Types::SymbolKind::Field, detail, tree)
      children = type_symbol.children ||= [] of Types::DocumentSymbol
      children << field
    end

    private def add_enum_members(
      enum_node : Facet::Compiler::SyntaxNode,
      output : Array(Types::DocumentSymbol),
      tree : Facet::Compiler::SyntaxTree,
    ) : Nil
      body = enum_node.body
      return unless body
      body.children.each do |entry|
        candidate = entry.kind == Facet::Compiler::NodeKind::Assign ? entry.target : entry
        next unless candidate
        next unless {Facet::Compiler::NodeKind::Ident, Facet::Compiler::NodeKind::Const}.includes?(candidate.kind)
        name = candidate.symbol_name
        next unless name && !name.empty? && name[0].ascii_uppercase?
        output << document_symbol(candidate, name, Types::SymbolKind::EnumMember, nil, tree)
      end
    end

    private def range_for(span : Facet::Compiler::Span, tree : Facet::Compiler::SyntaxTree) : Types::Range
      start_position = tree.position_at(span.start)
      end_position = tree.position_at(span.finish)
      Types::Range.new(
        Types::Position.new(start_position.line, start_position.character),
        Types::Position.new(end_position.line, end_position.character)
      )
    end

    private def qualify(container : String?, name : String) : String
      return name if name.includes?("::") || container.nil?
      "#{container}::#{name}"
    end

    private def flatten_symbol(
      symbol : Types::DocumentSymbol,
      flat : Array(Types::SymbolInformation),
      container : String?,
      uri : String,
    ) : Nil
      name = symbol.name
      if detail = symbol.detail
        suffix = detail.starts_with?("(") || detail.starts_with?(":") ? detail : " #{detail}"
        name = "#{name}#{suffix}"
      end
      flat << Types::SymbolInformation.new(
        name: name,
        kind: symbol.kind,
        location: Types::Location.new(uri: uri, range: symbol.range),
        container_name: container
      )
      symbol.children.try &.each { |child| flatten_symbol(child, flat, symbol.name, uri) }
    end
  end
end
