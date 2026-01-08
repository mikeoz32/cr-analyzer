require "./types"
require "./completion"
require "uri"
require "log"
require "compiler/crystal/syntax"
require "./semantic/alayst"
require "./workspace/ast_node_extensions"
require "./workspace/node_finder"
require "./workspace/document"
require "./workspace/document_symbols_index"
require "./workspace/keyword_completion_provider"
require "./workspace/require_path_completion_provider"

module CRA
  class Workspace
    Log = ::Log.for("CRA::Workspace")

    @completion_providers : Array(CompletionProvider) = [] of CompletionProvider
    @documents : Hash(String, WorkspaceDocument) = {} of String => WorkspaceDocument

    def self.from_s(uri : String)
      new(URI.parse(uri))
    end

    def self.from_uri(uri : URI)
      new(uri)
    end

    getter root : URI

    def initialize(@root : URI)
      raise "Only file:// URIs are supported" unless @root.scheme == "file"
      @path = Path.new(@root.path)
      @indexer = DocumentSymbolsIndex.new
      @analyzer = Psi::SemanticIndex.new
      @completion_providers << @analyzer
      @completion_providers << KeywordCompletionProvider.new
      @completion_providers << RequirePathCompletionProvider.new
    end

    def indexer : DocumentSymbolsIndex
      @indexer
    end

    def analyzer : Psi::SemanticIndex
      @analyzer
    end

    def document(uri : String) : WorkspaceDocument?
      @documents[uri] ||= WorkspaceDocument.new(URI.parse(uri))
    end

    def scan
      # Scan the workspace for Crystal files
      Log.info { "Scanning workspace at #{@root}" }
      seen = {} of String => Bool
      stdlib_paths.each { |path| scan_path(path, seen) }

      lib_path = @path.join("lib")
      scan_path(lib_path, seen) if Dir.exists?(lib_path.to_s)

      scan_path(@path, seen)
      @analyzer.dump_roots if ENV["CRA_DUMP_ROOTS"]? == "1"
    end

    private def stdlib_paths : Array(Path)
      paths = [] of Path
      if crystal_path = ENV["CRYSTAL_PATH"]?
        crystal_path.split(":").each do |entry|
          base = Path.new(entry)
          next unless Dir.exists?(base.to_s)
          src = base.join("src")
          paths << (Dir.exists?(src.to_s) ? src : base)
        end
      end

      if crystal_home = ENV["CRYSTAL_HOME"]?
        src = Path.new(crystal_home).join("src")
        paths << src if Dir.exists?(src.to_s)
      end

      if paths.empty?
        default = Path.new("/usr/share/crystal/src")
        paths << default if Dir.exists?(default.to_s)
      end
      paths.uniq
    end

    private def scan_path(path : Path, seen : Hash(String, Bool))
      return unless Dir.exists?(path.to_s)
      Dir.glob(path.join("**/*.cr").to_s) do |file_path|
        next if seen[file_path]?
        seen[file_path] = true
        index_file(file_path)
      end
    end

    private def index_file(file_path : String)
      parser = Crystal::Parser.new(File.read(file_path))
      parser.wants_doc = true
      program = parser.parse
      indexer.enter("file://#{file_path}")
      @analyzer.enter("file://#{file_path}")
      program.accept(indexer)
      @analyzer.index(program)
    rescue ex : Exception
      Log.error { "Error parsing #{file_path}: #{ex.message}" }
    end

    def reindex_file(uri : String, program : Crystal::ASTNode? = nil) : Array(String)
      reindexed = [] of String
      path = URI.parse(uri).path
      return reindexed unless File.exists?(path) || program

      old_types = @analyzer.type_names_for_file(uri)
      if program.nil?
        parser = Crystal::Parser.new(File.read(path))
        parser.wants_doc = true
        program = parser.parse
      end

      @analyzer.remove_file(uri)
      @analyzer.enter(uri)
      @analyzer.index(program)

      @indexer.enter(uri)
      program.accept(@indexer)
      reindexed << uri

      new_types = @analyzer.type_names_for_file(uri)
      changed_types = (old_types + new_types).uniq
      dependent_types = @analyzer.dependent_types_for(changed_types)
      dependent_files = @analyzer.files_for_types(dependent_types)

      dependent_files.each do |dep_uri|
        next if dep_uri == uri
        dep_path = URI.parse(dep_uri).path
        next unless File.exists?(dep_path)

        begin
          dep_parser = Crystal::Parser.new(File.read(dep_path))
          dep_parser.wants_doc = true
          dep_program = dep_parser.parse
        rescue ex : Exception
          Log.error { "Error parsing #{dep_path}: #{ex.message}" }
          next
        end

        @analyzer.remove_file(dep_uri)
        @analyzer.enter(dep_uri)
        @analyzer.index(dep_program)

        @indexer.enter(dep_uri)
        dep_program.accept(@indexer)
        reindexed << dep_uri
      end

      reindexed
    rescue ex : Exception
      Log.error { "Error reindexing #{uri}: #{ex.message}" }
      [] of String
    end

    def complete(request : Types::CompletionRequest) : Array(Types::CompletionItem)
      document = document(request.text_document.uri)
      return [] of Types::CompletionItem unless document

      finder = document.node_context(request.position)
      context = CompletionContext.new(
        request,
        request.text_document.uri,
        document.text,
        finder.node,
        finder.previous_node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        finder.context_path,
        @root
      )

      items = [] of Types::CompletionItem
      @completion_providers.each do |provider|
        items.concat(provider.complete(context))
      end

      seen = {} of String => Bool
      unique = [] of Types::CompletionItem
      items.each do |item|
        key = "#{item.label}:#{item.kind || "none"}"
        next if seen[key]?
        seen[key] = true
        unique << item
      end
      unique
    end

    def resolve_completion_item(item : Types::CompletionItem) : Types::CompletionItem
      return item if item.documentation
      data = item.data
      return item unless data

      data_hash = data.as_h?
      return item unless data_hash

      signature = data_hash["signature"]?.try(&.as_s?)
      doc = data_hash["doc"]?.try(&.as_s?)
      return item unless signature || doc

      if signature && !signature.empty?
        item.detail = signature unless item.detail == signature
      end
      item.documentation = markdown_documentation(signature, doc)
      item
    rescue ex
      Log.error { "Error resolving completion item: #{ex.message}" }
      item
    end

    def find_definitions(request : Types::DefinitionRequest) : Array(Types::Location)
      file = document request.text_document.uri
      position = request.position
      file.try do |doc|
        finder = doc.node_context(position)
        node = finder.node
        node.try do |n|
          Log.info { "Finding definitions for node: #{n.class} at #{n.location.inspect}" }
          locations = [] of Types::Location
          @analyzer.find_definitions(
            n,
            finder.enclosing_type_name,
            finder.enclosing_def,
            finder.enclosing_class,
            finder.cursor_location,
            request.text_document.uri
          ).each do |def_node|
            def_loc = def_node.location
            def_file = def_node.file
            next unless def_loc && def_file
            uri = def_file.starts_with?("file://") ? def_file : "file://#{def_file}"
            locations << Types::Location.new(
              uri: uri,
              range: def_loc.to_range
            )
          end
          return locations
        end
      end
      [] of Types::Location
    end

    def hover(request : Types::HoverRequest) : Types::Hover?
      document = document(request.text_document.uri)
      return nil unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return nil unless node

      definitions = @analyzer.find_definitions(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        request.text_document.uri
      )
      return nil if definitions.empty?

      Types::Hover.new(hover_contents(definitions), node.range)
    end

    def signature_help(request : Types::SignatureHelpRequest) : Types::SignatureHelp?
      document = document(request.text_document.uri)
      return nil unless document

      finder = document.node_context(request.position)
      call = call_for_signature_help(finder)
      return nil unless call

      cursor = finder.cursor_location
      return nil unless cursor && cursor_in_call?(call, cursor)

      methods = @analyzer.signature_help_methods(
        call,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        cursor
      )
      return nil if methods.empty?

      signatures = [] of Types::SignatureInformation
      signature_methods = [] of Psi::Method
      seen = {} of String => Bool

      methods.each do |method|
        label = hover_signature(method)
        next if seen[label]?
        seen[label] = true

        parameters = method.parameters.map { |param| Types::ParameterInformation.new(JSON::Any.new(param)) }
        signatures << Types::SignatureInformation.new(label, signature_documentation(method), parameters)
        signature_methods << method
      end
      return nil if signatures.empty?

      active_signature = active_signature_index(signature_methods, call)
      active_signature = 0 if active_signature.nil?
      active_method = signature_methods[active_signature]? || signature_methods.first?
      active_parameter = active_method ? active_parameter_index(call, cursor, active_method.parameters) : nil

      Types::SignatureHelp.new(signatures, active_signature, active_parameter)
    end

    def document_highlights(request : Types::DocumentHighlightRequest) : Array(Types::DocumentHighlight)
      document = document(request.text_document.uri)
      return [] of Types::DocumentHighlight unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return [] of Types::DocumentHighlight unless node

      case node
      when Crystal::Var
        highlights_for_local(node.name, finder.enclosing_def)
      when Crystal::Arg
        highlights_for_local(node.name, finder.enclosing_def)
      when Crystal::InstanceVar
        highlights_for_instance_var(node.name, finder.enclosing_class)
      when Crystal::ClassVar
        highlights_for_class_var(node.name, finder.enclosing_class)
      when Crystal::Path
        highlights_for_path(node, document.program)
      else
        [] of Types::DocumentHighlight
      end
    end

    def selection_ranges(request : Types::SelectionRangeRequest) : Array(Types::SelectionRange)
      document = document(request.text_document.uri)
      return [] of Types::SelectionRange unless document

      request.positions.map do |position|
        finder = document.node_context(position)
        selection_range_for_path(finder.context_path, position)
      end
    end

    private def hover_contents(definitions : Array(Psi::PsiElement)) : JSON::Any
      sections = [] of String
      seen = {} of String => Bool

      definitions.each do |definition|
        section = hover_section(definition)
        next if seen[section]?
        seen[section] = true
        sections << section
      end

      value = sections.join("\n\n---\n\n")
      JSON::Any.new({
        "kind" => JSON::Any.new("markdown"),
        "value" => JSON::Any.new(value),
      })
    end

    private def markdown_documentation(signature : String?, doc : String?) : JSON::Any
      sections = [] of String
      signature = signature.try(&.strip)
      doc = doc.try(&.strip)

      if signature && !signature.empty?
        sections << "```crystal\n#{signature}\n```"
      end
      if doc && !doc.empty?
        sections << doc
      end

      JSON::Any.new({
        "kind" => JSON::Any.new("markdown"),
        "value" => JSON::Any.new(sections.join("\n\n")),
      })
    end

    private def hover_section(definition : Psi::PsiElement) : String
      signature = hover_signature(definition)
      content = "```crystal\n#{signature}\n```"

      if doc = definition.doc
        doc = doc.strip
        content += "\n\n#{doc}" unless doc.empty?
      end
      content
    end

    private def hover_signature(definition : Psi::PsiElement) : String
      case definition
      when Psi::Method
        owner_name = definition.owner.try(&.name) || "self"
        separator = definition.class_method ? "." : "#"
        params = definition.parameters.join(", ")
        signature = "def #{owner_name}#{separator}#{definition.name}"
        signature += "(#{params})" unless params.empty?
        if definition.return_type_ref
          signature += " : #{definition.return_type}"
        end
        signature
      when Psi::Class
        "class #{@analyzer.type_signature_for(definition.name)}"
      when Psi::Module
        "module #{@analyzer.type_signature_for(definition.name)}"
      when Psi::Enum
        "enum #{@analyzer.type_signature_for(definition.name)}"
      when Psi::Alias
        if target = definition.target
          "alias #{definition.name} = #{target.display}"
        else
          "alias #{definition.name}"
        end
      when Psi::EnumMember
        "#{definition.owner.name}::#{definition.name}"
      when Psi::InstanceVar
        type_name = definition.type.empty? ? "Unknown" : definition.type
        "#{definition.name} : #{type_name}"
      when Psi::ClassVar
        type_name = definition.type.empty? ? "Unknown" : definition.type
        "#{definition.name} : #{type_name}"
      else
        definition.name
      end
    end

    private def signature_documentation(method : Psi::Method) : JSON::Any?
      doc = method.doc.try(&.strip)
      return nil unless doc && !doc.empty?

      JSON::Any.new({
        "kind" => JSON::Any.new("markdown"),
        "value" => JSON::Any.new(doc),
      })
    end

    private def active_signature_index(methods : Array(Psi::Method), call : Crystal::Call) : Int32?
      arity = call_arity(call)
      methods.each_with_index do |method, idx|
        next if arity < method.min_arity
        max = method.max_arity
        next if max && arity > max
        return idx
      end
      nil
    end

    private def call_arity(call : Crystal::Call) : Int32
      call.args.size + (call.named_args.try(&.size) || 0)
    end

    private def active_parameter_index(
      call : Crystal::Call,
      cursor : Crystal::Location,
      parameters : Array(String)
    ) : Int32?
      named_args = call.named_args || [] of Crystal::NamedArgument
      named_args.each_with_index do |named, idx|
        if cursor_in_node_range?(cursor, named)
          if param_index = parameters.index(named.name)
            return clamp_parameter_index(param_index, parameters)
          end
          return clamp_parameter_index(call.args.size + idx, parameters)
        end
      end

      call.args.each_with_index do |arg, idx|
        return clamp_parameter_index(idx, parameters) if cursor_in_node_range?(cursor, arg)
      end

      index = count_args_before_cursor(call, named_args, cursor)
      return clamp_parameter_index(index, parameters)
    end

    private def clamp_parameter_index(index : Int32, parameters : Array(String)) : Int32?
      return nil if parameters.empty?
      max_index = parameters.size - 1
      index = max_index if index > max_index
      index
    end

    private def count_args_before_cursor(
      call : Crystal::Call,
      named_args : Array(Crystal::NamedArgument),
      cursor : Crystal::Location
    ) : Int32
      index = 0
      call.args.each do |arg|
        end_loc = arg.end_location || arg.location
        next unless end_loc
        index += 1 if location_before_or_equal?(end_loc, cursor)
      end
      named_args.each do |named|
        end_loc = named.end_location || named.location
        next unless end_loc
        index += 1 if location_before_or_equal?(end_loc, cursor)
      end
      index
    end

    private def call_for_signature_help(finder : NodeFinder) : Crystal::Call?
      if call = finder.node.as?(Crystal::Call)
        return call
      end
      if call = finder.previous_node.as?(Crystal::Call)
        return call
      end

      finder.context_path.reverse_each do |node|
        if call = node.as?(Crystal::Call)
          return call
        end
      end
      nil
    end

    private def cursor_in_call?(call : Crystal::Call, cursor : Crystal::Location) : Bool
      return false unless call.has_parentheses? || call.has_any_args?

      start_loc = call.name_end_location || call.name_location || call.location
      return false unless start_loc
      end_loc = call.end_location || call.location
      return false unless end_loc

      location_after_or_equal?(cursor, start_loc) && location_before_or_equal?(cursor, end_loc)
    end

    private def cursor_in_node_range?(cursor : Crystal::Location, node : Crystal::ASTNode) : Bool
      start_loc = node.location
      return false unless start_loc
      end_loc = node.end_location || node.location
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

    private def highlights_for_local(name : String, scope_def : Crystal::Def?) : Array(Types::DocumentHighlight)
      return [] of Types::DocumentHighlight unless scope_def

      nodes = [] of Crystal::ASTNode
      scope_def.args.each do |arg|
        nodes << arg if arg.name == name
      end

      collector = LocalVarHighlightCollector.new(name)
      scope_def.body.accept(collector)
      nodes.concat(collector.nodes)

      document_highlights_for(nodes)
    end

    private def highlights_for_instance_var(name : String, scope_class : Crystal::ClassDef?) : Array(Types::DocumentHighlight)
      return [] of Types::DocumentHighlight unless scope_class

      collector = InstanceVarHighlightCollector.new(name)
      scope_class.body.accept(collector)
      document_highlights_for(collector.nodes)
    end

    private def highlights_for_class_var(name : String, scope_class : Crystal::ClassDef?) : Array(Types::DocumentHighlight)
      return [] of Types::DocumentHighlight unless scope_class

      collector = ClassVarHighlightCollector.new(name)
      scope_class.body.accept(collector)
      document_highlights_for(collector.nodes)
    end

    private def highlights_for_path(path : Crystal::Path, program : Crystal::ASTNode?) : Array(Types::DocumentHighlight)
      return [] of Types::DocumentHighlight unless program

      collector = PathHighlightCollector.new(path.full, path.global?)
      program.accept(collector)
      document_highlights_for(collector.nodes)
    end

    private def document_highlights_for(nodes : Array(Crystal::ASTNode)) : Array(Types::DocumentHighlight)
      highlights = [] of Types::DocumentHighlight
      seen = {} of String => Bool

      nodes.each do |node|
        range = node_name_range(node) || node_range(node)
        next unless range
        key = "#{range.start_position.line}:#{range.start_position.character}:#{range.end_position.line}:#{range.end_position.character}"
        next if seen[key]?
        seen[key] = true
        highlights << Types::DocumentHighlight.new(range)
      end

      highlights
    end

    private def selection_range_for_path(path : Array(Crystal::ASTNode), position : Types::Position) : Types::SelectionRange
      ranges = [] of Types::Range
      path.each do |node|
        if range = node_range(node)
          ranges << range
        end
      end

      if leaf = path.last?
        if name_range = node_name_range(leaf)
          if leaf_range = ranges.last?
            unless ranges_equal?(leaf_range, name_range)
              ranges << name_range
            end
          else
            ranges << name_range
          end
        end
      end

      if ranges.empty?
        fallback = Types::Range.new(
          start_position: position,
          end_position: position
        )
        return Types::SelectionRange.new(fallback)
      end

      parent : Types::SelectionRange? = nil
      ranges.each do |range|
        parent = Types::SelectionRange.new(range, parent)
      end
      parent.not_nil!
    end

    private def node_range(node : Crystal::ASTNode) : Types::Range?
      start_loc = node.location
      return nil unless start_loc
      end_loc = node.end_location || start_loc

      Types::Range.new(
        start_position: Types::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),
        end_position: Types::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number)
      )
    end

    private def node_name_range(node : Crystal::ASTNode) : Types::Range?
      case node
      when Crystal::Call
        loc = node.name_location || node.location
        return nil unless loc
        range_from_location_and_size(loc, node.name_size)
      when Crystal::Var
        loc = node.location
        return nil unless loc
        range_from_location_and_size(loc, node.name_size)
      when Crystal::Arg
        loc = node.location
        return nil unless loc
        range_from_location_and_size(loc, node.name_size)
      when Crystal::InstanceVar
        loc = node.location
        return nil unless loc
        range_from_location_and_size(loc, node.name_size)
      when Crystal::ClassVar
        loc = node.location
        return nil unless loc
        range_from_location_and_size(loc, node.name.size)
      when Crystal::Path
        loc = node.location
        return nil unless loc
        range_from_location_and_size(loc, node.name_size)
      else
        nil
      end
    end

    private def range_from_location_and_size(loc : Crystal::Location, size : Int32) : Types::Range
      start_line = loc.line_number - 1
      start_char = loc.column_number - 1
      end_char = start_char + size
      Types::Range.new(
        start_position: Types::Position.new(line: start_line, character: start_char),
        end_position: Types::Position.new(line: start_line, character: end_char)
      )
    end

    private def ranges_equal?(left : Types::Range, right : Types::Range) : Bool
      left.start_position.line == right.start_position.line &&
        left.start_position.character == right.start_position.character &&
        left.end_position.line == right.end_position.line &&
        left.end_position.character == right.end_position.character
    end
  end

  class LocalVarHighlightCollector < Crystal::Visitor
    getter nodes : Array(Crystal::ASTNode)

    def initialize(@name : String)
      @nodes = [] of Crystal::ASTNode
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Var) : Bool
      @nodes << node if node.name == @name
      true
    end

    def visit(node : Crystal::Arg) : Bool
      @nodes << node if node.name == @name
      true
    end

    def visit(node : Crystal::Def) : Bool
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      false
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end
  end

  class InstanceVarHighlightCollector < Crystal::Visitor
    getter nodes : Array(Crystal::ASTNode)

    def initialize(@name : String)
      @nodes = [] of Crystal::ASTNode
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::InstanceVar) : Bool
      @nodes << node if node.name == @name
      true
    end

    def visit(node : Crystal::ClassDef) : Bool
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      false
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end
  end

  class ClassVarHighlightCollector < Crystal::Visitor
    getter nodes : Array(Crystal::ASTNode)

    def initialize(@name : String)
      @nodes = [] of Crystal::ASTNode
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::ClassVar) : Bool
      @nodes << node if node.name == @name
      true
    end

    def visit(node : Crystal::ClassDef) : Bool
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      false
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end
  end

  class PathHighlightCollector < Crystal::Visitor
    getter nodes : Array(Crystal::ASTNode)

    def initialize(@full_name : String, @global : Bool)
      @nodes = [] of Crystal::ASTNode
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Path) : Bool
      if node.full == @full_name && node.global? == @global
        @nodes << node
      end
      true
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end
  end
end
