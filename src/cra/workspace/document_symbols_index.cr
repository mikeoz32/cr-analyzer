require "../completion"
require "compiler/crystal/syntax"
require "./ast_node_extensions"

module CRA
  class DocumentSymbolsIndex < Crystal::Visitor
    include CompletionProvider

    @current_uri : String?
    @container : String?
    def initialize
      # Document uri to symbols mapping
      @symbols = {} of String => Array(Types::SymbolInformation)
      @current_uri = nil
    end

    def enter(uri : String)
      @current_uri = uri
      @symbols[uri] = [] of Types::SymbolInformation
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Expressions) : Bool
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      symbol node.to_symbol_info(@current_uri, @container)
      @container = node.name.to_s
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::Def) : Bool
      node.accept_children(self)
      symbol node.to_symbol_info(@current_uri, @container)
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      node.accept_children(self)
      symbol node.to_symbol_info(@current_uri, @container)
      @current_parent = node.name.to_s
      false
    end

    def visit(node : Crystal::VarDef) : Bool
      symbol node.to_symbol_info(@current_uri, @container)
      false
    end

    def visit(node : Crystal::InstanceVar) : Bool
      symbol node.to_symbol_info(@current_uri, @container)
      false
    end

    def [](uri : String) : Array(Types::SymbolInformation)
      @symbols[uri] ||= [] of Types::SymbolInformation
    end

    def complete(context : CompletionContext) : Array(Types::CompletionItem)
      return [] of Types::CompletionItem if context.require_prefix

      trigger = context.trigger_character
      return [] of Types::CompletionItem if trigger == "." || trigger == "::" || trigger == "@"

      file = context.document_uri
      symbols = @symbols[file] || [] of CRA::Types::SymbolInformation
      result = [] of Types::CompletionItem
      return result unless trigger

      prefix = context.member_prefix(trigger)
      symbols.each do |symbol|
        next unless symbol.name.starts_with?(prefix)
        if symbol.kind == Types::SymbolKind::Method && trigger == "."
          result << Types::CompletionItem.new(
            label: symbol.name,
            kind: Types::CompletionItemKind::Method,
            detail: "Method from #{symbol.container_name || "global"}"
          )
        elsif symbol.kind == Types::SymbolKind::Class && trigger == "::"
          result << Types::CompletionItem.new(
            label: symbol.name,
            kind: Types::CompletionItemKind::Class,
            detail: "Class from #{symbol.container_name || "global"}"
          )
        elsif symbol.kind == Types::SymbolKind::Property && trigger == "@"
          result << Types::CompletionItem.new(
            label: symbol.name,
            kind: Types::CompletionItemKind::Property,
            detail: "Property from #{symbol.container_name || "global"}"
          )
        end
      end
      result
    end

    private def symbol(symbol : Types::SymbolInformation)
      if @current_uri
        @symbols[@current_uri] << symbol
      else
        raise "You must call enter(uri) before adding symbols"
      end
    end
  end
end
