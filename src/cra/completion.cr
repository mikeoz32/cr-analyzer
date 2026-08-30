require "./types"
require "uri"
require "compiler/crystal/syntax"
require "facet/compiler"

module CRA
  class CompletionContext
    getter request : Types::CompletionRequest
    getter document_uri : String
    getter document_text : String
    getter node : Crystal::ASTNode?
    getter previous_node : Crystal::ASTNode?
    getter enclosing_type_name : String?
    getter enclosing_def : Crystal::Def?
    getter enclosing_class : Crystal::ClassDef?
    getter cursor_location : Crystal::Location?
    getter trigger_character : String?
    getter line_prefix : String
    getter word_prefix : String
    getter node_path : Array(Crystal::ASTNode)
    getter facet_node : Facet::Compiler::SyntaxNode?
    getter facet_node_path : Array(Facet::Compiler::SyntaxNode)
    getter facet_cursor_offset : Int32?
    getter root : URI

    def initialize(
      @request : Types::CompletionRequest,
      @document_uri : String,
      @document_text : String,
      @node : Crystal::ASTNode?,
      @previous_node : Crystal::ASTNode?,
      @enclosing_type_name : String?,
      @enclosing_def : Crystal::Def?,
      @enclosing_class : Crystal::ClassDef?,
      @cursor_location : Crystal::Location?,
      @node_path : Array(Crystal::ASTNode),
      @facet_node : Facet::Compiler::SyntaxNode?,
      @facet_node_path : Array(Facet::Compiler::SyntaxNode),
      @facet_cursor_offset : Int32?,
      @root : URI,
    )
      @line_prefix = line_prefix_at(@document_text, @request.position)
      @word_prefix = word_prefix_from(@line_prefix)
      @trigger_character = @request.context.try(&.trigger_character) || infer_trigger(@line_prefix)
    end

    def require_prefix : String?
      if match = @line_prefix.match(/\brequire\s+["']([^"']*)$/)
        return match[1]
      end
      nil
    end

    def namespace_prefix : String?
      if match = @line_prefix.match(/([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)::$/)
        return match[1]
      end
      nil
    end

    def member_prefix(trigger : String?) : String
      return @word_prefix unless trigger

      case trigger
      when "."
        return "" if @line_prefix.ends_with?(".")
        if idx = @line_prefix.rindex(".")
          return @line_prefix[(idx + 1)..-1]? || ""
        end
      when "::"
        return "" if @line_prefix.ends_with?("::")
        if idx = @line_prefix.rindex("::")
          return @line_prefix[(idx + 2)..-1]? || ""
        end
      when "@"
        return @word_prefix
      end
      @word_prefix
    end

    private def infer_trigger(prefix : String) : String?
      return "::" if prefix.ends_with?("::")
      return "." if prefix.ends_with?(".")
      return "@" if prefix.ends_with?("@")
      nil
    end

    private def word_prefix_from(prefix : String) : String
      if match = prefix.match(/[@A-Za-z_][A-Za-z0-9_!?@]*$/)
        return match[0]
      end
      ""
    end

    private def line_prefix_at(text : String, position : Types::Position) : String
      source = Facet::Compiler::Source.new(text, @document_uri)
      line_index = Facet::Compiler::LineIndex.new(source)
      return "" unless position.line.in?(0...line_index.line_starts.size)
      cursor = @facet_cursor_offset || line_index.offset_at(
        Facet::Compiler::TextPosition.new(position.line, position.character),
        Facet::Compiler::PositionEncoding::Utf16
      )
      line_start = line_index.line_starts[position.line]
      text.byte_slice(line_start, Math.max(cursor - line_start, 0))
    end
  end

  module CompletionProvider
    abstract def complete(context : CompletionContext) : Array(Types::CompletionItem)
  end
end
