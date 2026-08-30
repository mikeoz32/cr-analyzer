require "../completion"
require "compiler/crystal/syntax"

module CRA
  class KeywordCompletionProvider
    include CompletionProvider

    TOP_LEVEL_KEYWORDS = %w[
      require class module struct enum lib alias def macro include extend abstract private protected
      getter setter property
    ]

    TYPE_BODY_KEYWORDS = %w[
      def macro include extend abstract private protected getter setter property
      class module struct enum lib alias
    ]

    BODY_KEYWORDS = %w[
      if unless case while until for in begin return yield
      self super nil true false
    ]

    CONDITION_KEYWORDS = %w[
      true false nil self super
    ]

    LOOP_KEYWORDS = %w[
      break next
    ]

    IF_KEYWORDS = %w[
      else elsif
    ]

    UNLESS_KEYWORDS = %w[
      else
    ]

    CASE_KEYWORDS = %w[
      when else
    ]

    BEGIN_KEYWORDS = %w[
      rescue ensure
    ]

    def complete(context : CompletionContext) : Array(Types::CompletionItem)
      return [] of Types::CompletionItem if context.require_prefix

      trigger = context.trigger_character
      return [] of Types::CompletionItem if trigger == "." || trigger == "::" || trigger == "@"

      prefix = context.word_prefix
      keywords = keywords_for_context(context)
      seen = {} of String => Bool
      items = [] of Types::CompletionItem

      keywords.each do |keyword|
        next if seen[keyword]?
        seen[keyword] = true
        next unless prefix.empty? || keyword.starts_with?(prefix)
        items << Types::CompletionItem.new(
          label: keyword,
          kind: Types::CompletionItemKind::Keyword
        )
      end
      items
    end

    private def keywords_for_context(context : CompletionContext) : Array(String)
      unless context.facet_node_path.empty?
        return facet_keywords_for_context(context)
      end

      crystal_keywords_for_context(context)
    end

    private def facet_keywords_for_context(context : CompletionContext) : Array(String)
      return CONDITION_KEYWORDS if facet_condition_context?(context)

      path = context.facet_node_path
      keywords = [] of String
      in_def = path.any? { |node| node.kind == Facet::Compiler::NodeKind::Def }
      in_type = path.any? do |node|
        {
          Facet::Compiler::NodeKind::Class,
          Facet::Compiler::NodeKind::Module,
          Facet::Compiler::NodeKind::Struct,
          Facet::Compiler::NodeKind::Enum,
          Facet::Compiler::NodeKind::Lib,
        }.includes?(node.kind)
      end
      in_if = path.any? { |node| node.kind == Facet::Compiler::NodeKind::If }
      in_unless = path.any? { |node| node.kind == Facet::Compiler::NodeKind::Unless }
      in_case = path.any? { |node| node.kind == Facet::Compiler::NodeKind::Case }
      in_exception = path.any? do |node|
        {
          Facet::Compiler::NodeKind::Begin,
          Facet::Compiler::NodeKind::Rescue,
          Facet::Compiler::NodeKind::Ensure,
        }.includes?(node.kind)
      end
      in_loop = path.any? do |node|
        {
          Facet::Compiler::NodeKind::While,
          Facet::Compiler::NodeKind::Until,
          Facet::Compiler::NodeKind::For,
        }.includes?(node.kind)
      end

      if in_def
        keywords.concat(BODY_KEYWORDS)
      else
        keywords.concat(TOP_LEVEL_KEYWORDS)
        keywords.concat(TYPE_BODY_KEYWORDS) if in_type
      end

      keywords.concat(LOOP_KEYWORDS) if in_loop
      keywords.concat(IF_KEYWORDS) if in_if
      keywords.concat(UNLESS_KEYWORDS) if in_unless
      keywords.concat(CASE_KEYWORDS) if in_case
      keywords.concat(BEGIN_KEYWORDS) if in_exception
      keywords
    end

    private def facet_condition_context?(context : CompletionContext) : Bool
      cursor = context.facet_cursor_offset
      return false unless cursor

      context.facet_node_path.reverse_each do |node|
        next unless condition = node.condition
        return condition.span.start <= cursor <= condition.span.finish
      end
      false
    end

    private def crystal_keywords_for_context(context : CompletionContext) : Array(String)
      return CONDITION_KEYWORDS if condition_context?(context)

      keywords = [] of String
      in_def = !context.enclosing_def.nil?
      in_type = context.node_path.any? do |node|
        node.is_a?(Crystal::ClassDef) || node.is_a?(Crystal::ModuleDef) || node.is_a?(Crystal::EnumDef)
      end
      in_if = context.node_path.any?(&.is_a?(Crystal::If))
      in_unless = context.node_path.any?(&.is_a?(Crystal::Unless))
      in_case = context.node_path.any?(&.is_a?(Crystal::Case))
      in_exception = context.node_path.any?(&.is_a?(Crystal::ExceptionHandler))
      in_loop = context.node_path.any? do |node|
        node.is_a?(Crystal::While) || node.is_a?(Crystal::Until)
      end

      if in_def
        keywords.concat(BODY_KEYWORDS)
      else
        keywords.concat(TOP_LEVEL_KEYWORDS)
        keywords.concat(TYPE_BODY_KEYWORDS) if in_type
      end

      keywords.concat(LOOP_KEYWORDS) if in_loop
      keywords.concat(IF_KEYWORDS) if in_if
      keywords.concat(UNLESS_KEYWORDS) if in_unless
      keywords.concat(CASE_KEYWORDS) if in_case
      keywords.concat(BEGIN_KEYWORDS) if in_exception

      keywords
    end

    private def condition_context?(context : CompletionContext) : Bool
      cursor = context.cursor_location
      return false unless cursor

      context.node_path.reverse_each do |node|
        case node
        when Crystal::If
          return in_node_range?(cursor, node.cond)
        when Crystal::Unless
          return in_node_range?(cursor, node.cond)
        when Crystal::While
          return in_node_range?(cursor, node.cond)
        when Crystal::Until
          return in_node_range?(cursor, node.cond)
        when Crystal::Case
          return in_node_range?(cursor, node.cond) if node.cond
        when Crystal::When
          first = node.conds.first?
          last = node.conds.last?
          return in_node_range?(cursor, first, last) if first
        end
      end

      false
    end

    private def in_node_range?(cursor : Crystal::Location, start_node : Crystal::ASTNode?, end_node : Crystal::ASTNode? = nil) : Bool
      return false unless start_node
      start_loc = start_node.location
      return false unless start_loc
      end_loc = (end_node || start_node).end_location || (end_node || start_node).location
      return false unless end_loc

      location_after_or_equal?(cursor, start_loc) && location_before_or_equal?(cursor, end_loc)
    end

    private def location_before_or_equal?(left : Crystal::Location, right : Crystal::Location) : Bool
      left.line_number < right.line_number ||
        (left.line_number == right.line_number && left.column_number <= right.column_number)
    end

    private def location_after_or_equal?(left : Crystal::Location, right : Crystal::Location) : Bool
      left.line_number > right.line_number ||
        (left.line_number == right.line_number && left.column_number >= right.column_number)
    end
  end
end
