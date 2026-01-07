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
  end
end
