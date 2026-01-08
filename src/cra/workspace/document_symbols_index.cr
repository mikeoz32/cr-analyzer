require "../completion"
require "compiler/crystal/syntax"
require "./ast_node_extensions"

module CRA
  class DocumentSymbolsIndex < Crystal::Visitor
    include CompletionProvider

    @current_uri : String?
    @container_stack : Array(String)
    def initialize
      # Document uri to symbols mapping
      @symbols = {} of String => Array(Types::SymbolInformation)
      @current_uri = nil
      @container_stack = [] of String
    end

    def enter(uri : String)
      @current_uri = uri
      @symbols[uri] = [] of Types::SymbolInformation
      @container_stack.clear
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Expressions) : Bool
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      symbol node.to_symbol_info(@current_uri, current_container)
      push_container(node.name.to_s)
      node.accept_children(self)
      @container_stack.pop
      false
    end

    def visit(node : Crystal::Def) : Bool
      symbol node.to_symbol_info(@current_uri, current_container)
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      symbol node.to_symbol_info(@current_uri, current_container)
      push_container(node.name.to_s)
      node.accept_children(self)
      @container_stack.pop
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      symbol node.to_symbol_info(@current_uri, current_container)
      push_container(node.name.to_s)
      node.accept_children(self)
      @container_stack.pop
      false
    end

    def visit(node : Crystal::VarDef) : Bool
      symbol node.to_symbol_info(@current_uri, current_container)
      false
    end

    def visit(node : Crystal::InstanceVar) : Bool
      symbol node.to_symbol_info(@current_uri, current_container)
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

    private def current_container : String?
      @container_stack.last?
    end

    private def push_container(name : String)
      if name.includes?("::")
        @container_stack << name
      elsif parent = @container_stack.last?
        @container_stack << "#{parent}::#{name}"
      else
        @container_stack << name
      end
    end
  end
end
