require "../types"
require "uri"
require "compiler/crystal/syntax"
require "./node_finder"

module CRA
  class WorkspaceDocument
    getter path : String

    getter program : Crystal::ASTNode?
    getter text : String

    def initialize(@uri : URI)
      @path = @uri.path
      @text = File.exists?(@path) ? File.read(@path) : ""
      parse(@text)
    end

    def update(text : String)
      @text = text
      parse(@text)
    end

    def apply_changes(changes : Array(Types::TextDocumentContentChangeEvent))
      changes.each do |change|
        if range = change.range
          apply_range_change(range, change.text)
        else
          @text = change.text
        end
      end
      parse(@text)
    end

    def reload_from_disk
      return unless File.exists?(@path)
      @text = File.read(@path)
      parse(@text)
    end

    def node_context(position : Types::Position) : NodeFinder
      finder = NodeFinder.new(position)
      @program.try do |prog|
        prog.accept(finder)
      end
      finder
    end

    def node_at(position : Types::Position) : Crystal::ASTNode?
      node_context(position).node
    end

    private def parse(text : String)
      lexer = Crystal::Parser.new(text)
      @program = lexer.parse
    end

    private def apply_range_change(range : Types::Range, new_text : String)
      start_index = offset_for(@text, range.start_position)
      end_index = offset_for(@text, range.end_position)

      prefix = @text.byte_slice(0, start_index) || ""
      suffix = @text.byte_slice(end_index, @text.bytesize - end_index) || ""
      @text = "#{prefix}#{new_text}#{suffix}"
    end

    private def offset_for(text : String, position : Types::Position) : Int32
      target_line = position.line
      target_column = position.character
      index = 0
      current_line = 0

      text.each_line do |line|
        if current_line == target_line
          return index + target_column
        end
        index += line.bytesize
        current_line += 1
      end

      index + target_column
    end
  end
end
