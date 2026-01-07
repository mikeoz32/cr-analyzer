require "./types"
require "uri"
require "compiler/crystal/syntax"

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
      @root : URI
    )
      line = line_at(@document_text, @request.position.line)
      @line_prefix = line[0, @request.position.character]? || line
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

    private def line_at(text : String, target_line : Int32) : String
      current_line = 0
      text.each_line do |line|
        if current_line == target_line
          return line.chomp("\n").chomp("\r")
        end
        current_line += 1
      end
      ""
    end
  end

  module CompletionProvider
    abstract def complete(context : CompletionContext) : Array(Types::CompletionItem)
  end
end
