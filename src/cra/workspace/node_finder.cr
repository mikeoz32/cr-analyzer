require "../types"
require "compiler/crystal/syntax"

module CRA
  class NodeFinder < Crystal::Visitor
    @position : Types::Position

    getter node : Crystal::ASTNode?
    getter previous_node : Crystal::ASTNode?
    @node_path : Array(Crystal::ASTNode)
    @previous_node_path : Array(Crystal::ASTNode)
    @stack : Array(Crystal::ASTNode)
    @previous_end : Crystal::Location?

    def initialize(@position : Types::Position)
      @line = @position.line
      @column = @position.character
      @node_path = [] of Crystal::ASTNode
      @previous_node_path = [] of Crystal::ASTNode
      @stack = [] of Crystal::ASTNode
      @cursor_location = Crystal::Location.new(
        filename: "",
        line_number: @line + 1,
        column_number: @column + 1
      )
      @location = @cursor_location
    end

    def visit(node : Crystal::ASTNode) : Bool
      return false unless traversable?(node)
      @stack << node
      if hits?(node)
        @node = node
        @node_path = @stack.dup
      end
      update_previous(node)
      node.accept_children(self)
      @stack.pop
      false
    end

    def enclosing_type_name : String?
      path = context_path
      names = [] of String
      path.each do |node|
        type_name = case node
                    when Crystal::ClassDef
                      node.name.full
                    when Crystal::ModuleDef
                      node.name.full
                    when Crystal::EnumDef
                      node.name.full
                    else
                      nil
                    end
        next unless type_name

        if type_name.includes?("::")
          names = [type_name]
        else
          names << type_name
        end
      end
      return nil if names.empty?
      names.join("::")
    end

    def enclosing_def : Crystal::Def?
      context_path.reverse_each do |node|
        return node if node.is_a?(Crystal::Def)
      end
      nil
    end

    def enclosing_class : Crystal::ClassDef?
      context_path.reverse_each do |node|
        return node if node.is_a?(Crystal::ClassDef)
      end
      nil
    end

    def cursor_location : Crystal::Location
      @location
    end

    def context_path : Array(Crystal::ASTNode)
      return @node_path unless @node_path.empty?
      @previous_node_path
    end

    private def traversable?(node : Crystal::ASTNode) : Bool
      return true if node.is_a?(Crystal::When)
      return true unless node.location

      loc = node.location.as(Crystal::Location)

      end_loc = node.end_location || loc
      return true if location_before_or_equal?(end_loc, @cursor_location)

      position_in?(loc, end_loc)
    end

    private def hits?(node : Crystal::ASTNode) : Bool
      if range = name_range(node)
        return true if position_in?(range[:start], range[:end])
      end

      if node.location && node.end_location
        return position_in?(node.location.as(Crystal::Location), node.end_location.as(Crystal::Location))
      end

      false
    end

    private def name_range(node : Crystal::ASTNode) : {start: Crystal::Location, end: Crystal::Location}?
      loc = node.name_location || node.location
      return nil unless loc

      size = node.name_size
      return nil if size <= 0

      end_loc = Crystal::Location.new(
        filename: loc.filename,
        line_number: loc.line_number,
        column_number: loc.column_number + size - 1
      )
      {start: loc, end: end_loc}
    end

    private def position_in?(start_loc : Crystal::Location, end_loc : Crystal::Location) : Bool
      @location = Crystal::Location.new(
        filename: start_loc.filename,
        line_number: @location.line_number,
        column_number: @location.column_number
      )
      @location.between?(start_loc, end_loc)
    end

    private def update_previous(node : Crystal::ASTNode)
      end_loc = node.end_location || node.location
      return unless end_loc
      return unless location_before_or_equal?(end_loc, @cursor_location)

      if @previous_end.nil? || location_before_or_equal?(@previous_end.not_nil!, end_loc)
        @previous_node = node
        @previous_node_path = @stack.dup
        @previous_end = end_loc
      end
    end

    private def location_before_or_equal?(left : Crystal::Location, right : Crystal::Location) : Bool
      left.line_number < right.line_number ||
        (left.line_number == right.line_number && left.column_number <= right.column_number)
    end
  end
end
