require "../types"
require "uri"
require "compiler/crystal/syntax"
require "./visitor_helpers"
require "./node_finder"
require "./facet_node_finder"
require "./facet_document_store"

module CRA
  class WorkspaceDocument
    getter path : String

    getter program : Crystal::ASTNode?
    getter text : String
    getter diagnostics : Array(Types::Diagnostic)
    getter facet_syntax : Facet::Compiler::SyntaxTree?
    @last_parse_error : Crystal::SyntaxException?

    def initialize(@uri : URI, @facet_store : FacetDocumentStore)
      @path = @uri.path
      @text = File.exists?(@path) ? File.read(@path) : ""
      @diagnostics = [] of Types::Diagnostic
      parse(@text)
    end

    def update(text : String)
      return if text == @text
      @text = text
      parse(@text)
    end

    def apply_changes(changes : Array(Types::TextDocumentContentChangeEvent))
      previous_text = @text
      changes.each do |change|
        if range = change.range
          apply_range_change(range, change.text)
        else
          @text = change.text
        end
      end
      return if @text == previous_text
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

    def facet_node_context(position : Types::Position) : FacetNodeFinder?
      @facet_syntax.try { |tree| FacetNodeFinder.new(tree, position) }
    end

    private def parse(text : String)
      @program = nil
      @facet_syntax = nil
      @last_parse_error = nil
      begin
        snapshot = @facet_store.update(@uri.to_s, text, @path)
        @facet_syntax = snapshot.syntax
      rescue
        # Crystal parsing and fallback diagnostics remain available if Facet
        # itself encounters an unexpected internal error.
      end
      begin
        parser = Crystal::Parser.new(text)
        parser.wants_doc = true
        @program = parser.parse
      rescue ex : Crystal::SyntaxException
        @last_parse_error = ex
      rescue
        # keep @program as nil on parse error; diagnostics will be filled below
      ensure
        parse_diagnostics(text)
      end
    end

    private def apply_range_change(range : Types::Range, new_text : String)
      start_index = offset_for(@text, range.start_position)
      end_index = offset_for(@text, range.end_position)

      prefix = @text.byte_slice(0, start_index) || ""
      suffix = @text.byte_slice(end_index, @text.bytesize - end_index) || ""
      @text = "#{prefix}#{new_text}#{suffix}"
    end

    private def offset_for(text : String, position : Types::Position) : Int32
      line_index = Facet::Compiler::LineIndex.new(Facet::Compiler::Source.new(text, @path))
      line_index.offset_at(
        Facet::Compiler::TextPosition.new(position.line, position.character),
        Facet::Compiler::PositionEncoding::Utf16
      )
    end

    private def parse_diagnostics(text : String)
      @diagnostics.clear
      if ENV["CRA_DISABLE_FACET_DIAGNOSTICS"]? == "1"
        add_parser_error_diagnostic
        add_todo_warnings(text)
        add_unused_arg_warnings
        return
      end

      begin
        syntax = @facet_syntax || raise "Facet syntax query unavailable"
        syntax.ast.diagnostics.each do |diag|
          start_location = syntax.position_at(diag.span.start)
          end_location = syntax.position_at(diag.span.finish)
          start_pos = Types::Position.new(line: start_location.line, character: start_location.character)
          end_pos = Types::Position.new(line: end_location.line, character: end_location.character)
          severity = diag.severity == Facet::Compiler::Diagnostic::Severity::Warning ? Types::DiagnosticSeverity::Warning : Types::DiagnosticSeverity::Error
          @diagnostics << Types::Diagnostic.new(
            range: Types::Range.new(start_pos, end_pos),
            severity: severity,
            message: diag.message,
            source: "facet"
          )
        end
      rescue
        @diagnostics.clear
        add_parser_error_diagnostic
      ensure
        @last_parse_error = nil
        add_todo_warnings(text)
        add_unused_arg_warnings
      end
    end

    private def add_parser_error_diagnostic
      return unless err = @last_parse_error
      line = err.responds_to?(:line_number) ? err.line_number : nil
      column = err.responds_to?(:column_number) ? err.column_number : nil
      return unless line && column

      start_pos = Types::Position.new(line: line - 1, character: column - 1)
      end_pos = Types::Position.new(line: line - 1, character: column)
      @diagnostics << Types::Diagnostic.new(
        range: Types::Range.new(start_pos, end_pos),
        severity: Types::DiagnosticSeverity::Error,
        message: err.message || "Syntax error",
        source: "crystal-parser"
      )
    end

    private def add_todo_warnings(text : String)
      seen_requires = {} of String => {first_line: Int32, duplicates: Array(Int32)}
      lines = text.lines
      lines.each_with_index do |line, idx|
        if match = line.match(/(TODO|FIXME)/)
          start_char = match.begin(0)
          end_char = match.end(0)
          start_pos = Types::Position.new(line: idx, character: start_char)
          end_pos = Types::Position.new(line: idx, character: end_char)
          @diagnostics << Types::Diagnostic.new(
            range: Types::Range.new(start_pos, end_pos),
            severity: Types::DiagnosticSeverity::Warning,
            message: "Todo/Fixme: #{match[0]}",
            source: "todo"
          )
        end

        if line.strip == "rescue"
          start_pos = Types::Position.new(line: idx, character: 0)
          end_pos = Types::Position.new(line: idx, character: line.size)
          @diagnostics << Types::Diagnostic.new(
            range: Types::Range.new(start_pos, end_pos),
            severity: Types::DiagnosticSeverity::Warning,
            message: "Empty rescue block?",
            source: "lint"
          )
        end

        if line =~ /\S\s+$/
          start_pos = Types::Position.new(line: idx, character: line.rstrip.size)
          end_pos = Types::Position.new(line: idx, character: line.size)
          @diagnostics << Types::Diagnostic.new(
            range: Types::Range.new(start_pos, end_pos),
            severity: Types::DiagnosticSeverity::Hint,
            message: "Trailing whitespace",
            source: "lint"
          )
        end

        if req = line.match(/^\s*require\s+["'](.+?)["']/)
          path = req[1]
          if entry = seen_requires[path]?
            entry[:duplicates] << idx
          else
            seen_requires[path] = {first_line: idx, duplicates: [] of Int32}
          end
        end
      end

      seen_requires.each do |path, data|
        data[:duplicates].each do |dup_line|
          start_pos = Types::Position.new(line: dup_line, character: 0)
          end_pos = Types::Position.new(line: dup_line, character: lines[dup_line]?.try(&.size) || 1)
          @diagnostics << Types::Diagnostic.new(
            range: Types::Range.new(start_pos, end_pos),
            severity: Types::DiagnosticSeverity::Hint,
            message: "Duplicate require '#{path}' (first at line #{data[:first_line] + 1})",
            source: "lint"
          )
        end
      end

      unless text.ends_with?("\n")
        line_idx = lines.size - 1
        start_pos = Types::Position.new(line: line_idx < 0 ? 0 : line_idx, character: (lines.last?.try(&.size) || 0))
        end_pos = start_pos
        @diagnostics << Types::Diagnostic.new(
          range: Types::Range.new(start_pos, end_pos),
          severity: Types::DiagnosticSeverity::Hint,
          message: "File does not end with a newline",
          source: "lint"
        )
      end

      mixed_indent_lines(lines)
    end

    private def mixed_indent_lines(lines : Array(String))
      lines.each_with_index do |line, idx|
        leading = nil
        if match = /^\s+/.match(line)
          leading = match[0]?
        end
        next unless leading
        if leading.includes?("\t") && leading.includes?(" ")
          start_pos = Types::Position.new(line: idx, character: 0)
          end_pos = Types::Position.new(line: idx, character: leading.size)
          @diagnostics << Types::Diagnostic.new(
            range: Types::Range.new(start_pos, end_pos),
            severity: Types::DiagnosticSeverity::Hint,
            message: "Mixed tabs and spaces in indentation",
            source: "lint"
          )
        end
      end
    end

    private def add_unused_arg_warnings
      return unless program = @program
      collector = UnusedArgCollector.new(@diagnostics)
      program.accept(collector)
      block_collector = UnusedBlockArgCollector.new(@diagnostics)
      program.accept(block_collector)
    end

    # Collect unused def args (ignores names starting with underscore).
    class UnusedArgCollector < Crystal::Visitor
      include Workspace::VisitorHelpers

      def initialize(@diagnostics : Array(CRA::Types::Diagnostic))
      end

      continue_all

      def visit(node : Crystal::Def) : Bool
        args = node.args.reject { |arg| arg.name.starts_with?("_") }
        return true if args.empty?

        used = collect_used_vars(node.body)
        args.each do |arg|
          next if used.includes?(arg.name)
          add_unused(arg)
        end
        false
      end

      private def collect_used_vars(node : Crystal::ASTNode?) : Set(String)
        used = Set(String).new
        return used unless node
        visitor = UsedVarCollector.new(used)
        node.accept(visitor)
        used
      end

      private def add_unused(arg : Crystal::Arg)
        if loc = arg.location
          start_pos = CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1)
          end_pos = CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1 + arg.name_size)
          @diagnostics << CRA::Types::Diagnostic.new(
            range: CRA::Types::Range.new(start_pos, end_pos),
            severity: CRA::Types::DiagnosticSeverity::Hint,
            message: "Unused argument '#{arg.name}'",
            source: "lint"
          )
        end
      end
    end

    # Tracks variable usage inside def bodies (ignores nested defs).
    class UsedVarCollector < Crystal::Visitor
      include Workspace::VisitorHelpers

      def initialize(@used : Set(String))
      end

      continue_all
      stop_at Crystal::Def, Crystal::ClassDef, Crystal::ModuleDef

      def visit(node : Crystal::Var | Crystal::Arg) : Bool
        @used << node.name
        true
      end
    end

    # Collect unused block args (ignores names starting with underscore).
    class UnusedBlockArgCollector < Crystal::Visitor
      include Workspace::VisitorHelpers

      def initialize(@diagnostics : Array(CRA::Types::Diagnostic))
      end

      continue_all
      stop_at Crystal::Def, Crystal::ClassDef, Crystal::ModuleDef

      def visit(node : Crystal::Block) : Bool
        args = node.args.reject { |arg| arg.name.starts_with?("_") }
        return true if args.empty?

        used = Set(String).new
        node.body.try(&.accept(UsedVarCollector.new(used)))
        args.each do |arg|
          next if used.includes?(arg.name)
          add_unused(arg)
        end
        false
      end

      private def add_unused(arg : Crystal::ASTNode)
        loc = arg.location
        name = arg.responds_to?(:name) ? arg.name : nil
        size = arg.responds_to?(:name_size) ? arg.name_size : name.try(&.size) || 0
        return unless loc && name

        start_pos = CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1)
        end_pos = CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1 + size)
        @diagnostics << CRA::Types::Diagnostic.new(
          range: CRA::Types::Range.new(start_pos, end_pos),
          severity: CRA::Types::DiagnosticSeverity::Hint,
          message: "Unused block argument '#{name}'",
          source: "lint"
        )
      end
    end
  end
end
