require "./types"
require "./completion"
require "uri"
require "log"
require "compiler/crystal/syntax"
require "./semantic/alayst"
require "./workspace/visitor_helpers"
require "./workspace/ast_node_extensions"
require "./workspace/node_finder"
require "./workspace/document"
require "./workspace/document_symbols_index"
require "./workspace/keyword_completion_provider"
require "./workspace/require_path_completion_provider"
require "./workspace/rename"

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
      unless ENV["CRA_SKIP_STDLIB_SCAN"]? == "1"
        stdlib_paths.each { |path| scan_path(path, seen) }
      end

      lib_path = @path.join("lib")
      scan_path(lib_path, seen) if Dir.exists?(lib_path.to_s)

      scan_path(@path, seen)
      @analyzer.resolve_pending_yield_types
      @analyzer.register_primitive_superclasses
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

      @analyzer.resolve_pending_yield_types
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
          definitions = @analyzer.find_definitions(
            n,
            finder.enclosing_type_name,
            effective_scope_def(finder, doc),
            finder.enclosing_class,
            finder.cursor_location,
            request.text_document.uri,
            proc_def: finder.enclosing_proc_def
          )
          return elements_to_locations(definitions)
        end
      end
      [] of Types::Location
    end

    def find_declarations(request : Types::DeclarationRequest) : Array(Types::Location)
      document = document(request.text_document.uri)
      return [] of Types::Location unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return [] of Types::Location unless node

      Log.info { "Finding declarations for node: #{node.class} at #{node.location.inspect}" }
      declarations = @analyzer.find_declarations(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        request.text_document.uri
      )
      elements_to_locations(declarations)
    end

    def find_type_definitions(request : Types::TypeDefinitionRequest) : Array(Types::Location)
      document = document(request.text_document.uri)
      return [] of Types::Location unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return [] of Types::Location unless node

      Log.info { "Finding type definitions for node: #{node.class} at #{node.location.inspect}" }
      definitions = @analyzer.find_type_definitions(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        request.text_document.uri
      )
      elements_to_locations(definitions)
    end

    def find_implementations(request : Types::ImplementationRequest) : Array(Types::Location)
      document = document(request.text_document.uri)
      return [] of Types::Location unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return [] of Types::Location unless node

      Log.info { "Finding implementations for node: #{node.class} at #{node.location.inspect}" }
      implementations = @analyzer.find_implementations(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        request.text_document.uri
      )
      elements_to_locations(implementations)
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
        effective_scope_def(finder, document),
        finder.enclosing_class,
        finder.cursor_location,
        request.text_document.uri,
        proc_def: finder.enclosing_proc_def
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

    def prepare_call_hierarchy(request : Types::CallHierarchyPrepareRequest) : Array(Types::CallHierarchyItem)
      document = document(request.text_document.uri)
      return [] of Types::CallHierarchyItem unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return [] of Types::CallHierarchyItem unless node

      definitions = @analyzer.find_definitions(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        request.text_document.uri
      )
      items = [] of Types::CallHierarchyItem
      seen = {} of String => Bool
      definitions.each do |definition|
        next unless item = call_hierarchy_item(definition)
        key = "#{item.name}:#{item.uri}:#{item.range.start_position.line}:#{item.range.start_position.character}"
        next if seen[key]?
        seen[key] = true
        items << item
      end
      items
    end

    def call_hierarchy_incoming(_request : Types::CallHierarchyIncomingCallsRequest) : Array(Types::CallHierarchyIncomingCall)
      methods = @analyzer.call_hierarchy_incoming_methods(_request.item)
      calls = [] of Types::CallHierarchyIncomingCall
      methods.each do |entry|
        method = entry[:method]
        ranges = entry[:ranges]
        if item = call_hierarchy_item(method)
          from_ranges = ranges.empty? ? (method.location.try(&.to_range) ? [method.location.not_nil!.to_range] : [] of Types::Range) : ranges
          calls << Types::CallHierarchyIncomingCall.new(item, from_ranges)
        end
      end
      calls
    end

    def call_hierarchy_outgoing(_request : Types::CallHierarchyOutgoingCallsRequest) : Array(Types::CallHierarchyOutgoingCall)
      methods = @analyzer.call_hierarchy_outgoing_methods(_request.item)
      calls = [] of Types::CallHierarchyOutgoingCall
      fallback_from = _request.item.selection_range
      methods.each do |entry|
        method = entry[:method]
        ranges = entry[:ranges]
        if item = call_hierarchy_item(method)
          from_ranges = ranges.empty? ? [fallback_from] : ranges
          calls << Types::CallHierarchyOutgoingCall.new(item, from_ranges)
        end
      end
      calls
    end

    def prepare_type_hierarchy(request : Types::TypeHierarchyPrepareRequest) : Array(Types::TypeHierarchyItem)
      document = document(request.text_document.uri)
      return [] of Types::TypeHierarchyItem unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return [] of Types::TypeHierarchyItem unless node

      definitions = case node
                    when Crystal::Path, Crystal::Generic, Crystal::ClassDef, Crystal::ModuleDef, Crystal::EnumDef
                      @analyzer.find_definitions(
                        node,
                        finder.enclosing_type_name,
                        finder.enclosing_def,
                        finder.enclosing_class,
                        finder.cursor_location,
                        request.text_document.uri
                      )
                    else
                      [] of Psi::PsiElement
                    end
      items = [] of Types::TypeHierarchyItem
      definitions.each do |definition|
        if item = type_hierarchy_item(definition)
          items << item
        end
      end
      items
    end

    def type_hierarchy_supertypes(request : Types::TypeHierarchySupertypesRequest) : Array(Types::TypeHierarchyItem)
      items = [] of Types::TypeHierarchyItem
      @analyzer.type_hierarchy_supertypes(request.item.name).each do |element|
        if item = type_hierarchy_item(element)
          items << item
        end
      end
      items
    end

    def type_hierarchy_subtypes(request : Types::TypeHierarchySubtypesRequest) : Array(Types::TypeHierarchyItem)
      items = [] of Types::TypeHierarchyItem
      @analyzer.type_hierarchy_subtypes(request.item.name).each do |element|
        if item = type_hierarchy_item(element)
          items << item
        end
      end
      items
    end

    def find_references(request : Types::ReferencesRequest) : Array(Types::Location)
      document = document(request.text_document.uri)
      return [] of Types::Location unless document

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return [] of Types::Location unless node

      include_decl = request.context.include_declaration
      case node
      when Crystal::Var
        references_for_local(node.name, finder.enclosing_def, request.text_document.uri, include_decl)
      when Crystal::Arg
        references_for_local(node.name, finder.enclosing_def, request.text_document.uri, include_decl)
      when Crystal::InstanceVar
        references_for_instance_var(node.name, finder.enclosing_class, request.text_document.uri, include_decl)
      when Crystal::ClassVar
        references_for_class_var(node.name, finder.enclosing_class, request.text_document.uri, include_decl)
      when Crystal::Call, Crystal::Def
        references_for_method(node, finder, request.text_document.uri, include_decl)
      when Crystal::Path
        refs = references_for_path(node.full, node.global?, document.program, request.text_document.uri)
        refs.concat(@analyzer.references_for_path(node.full, finder.enclosing_type_name, request.text_document.uri))
        refs
      else
        [] of Types::Location
      end
    end

    def inline_values(request : Types::InlineValueRequest) : Array(Types::InlineValue)
      document = document(request.text_document.uri)
      return [] of Types::InlineValue unless document
      program = document.program
      return [] of Types::InlineValue unless program

      collector = InlineValueCollector.new(request.range)
      program.accept(collector)
      collector.values
    end

    def document_diagnostics(request : Types::DocumentDiagnosticRequest) : Types::DocumentDiagnosticReport
      document = document(request.text_document.uri)
      return Types::DocumentDiagnosticReportFull.new([] of Types::Diagnostic) unless document

      Types::DocumentDiagnosticReportFull.new(document.diagnostics)
    end

    def workspace_symbols(request : Types::WorkspaceSymbolRequest) : Array(Types::SymbolInformation)
      query = request.query
      results = [] of Types::SymbolInformation
      seen = {} of String => Bool

      @indexer.symbols.each_key do |uri|
        @indexer.symbol_informations(uri).each do |info|
          next unless info.name.includes?(query)
          key = "#{info.name}:#{info.location.uri}:#{info.location.range.start_position.line}:#{info.location.range.start_position.character}"
          next if seen[key]?
          seen[key] = true
          results << info
        end
      end

      results
    end

    def publish_diagnostics(uri : String) : Types::PublishDiagnosticsParams
      document = document(uri)
      diags = document ? document.diagnostics : [] of Types::Diagnostic
      Types::PublishDiagnosticsParams.new(uri: uri, diagnostics: diags)
    end

    private def elements_to_locations(elements : Array(Psi::PsiElement)) : Array(Types::Location)
      locations = [] of Types::Location
      seen = {} of String => Bool
      elements.each do |def_node|
        def_loc = def_node.location
        def_file = def_node.file
        next unless def_loc && def_file
        uri, range = resolve_macro_uri(def_file, def_loc)
        key = "#{uri}:#{range.start_position.line}:#{range.start_position.character}:#{range.end_position.line}:#{range.end_position.character}"
        next if seen[key]?
        seen[key] = true
        locations << Types::Location.new(uri: uri, range: range)
      end
      locations
    end

    private def resolve_macro_uri(file : String, loc : Psi::Location) : {String, Types::Range}
      if file.starts_with?("crystal-macro:")
        # Format: crystal-macro:{path}/{macro_name}/{line}_{col}.cr
        raw = file.sub("crystal-macro:", "")
        if match = raw.match(/^(.+)\/\w+\/(\d+)_(\d+)\.cr$/)
          original_path = match[1]
          line = match[2].to_i - 1
          col = match[3].to_i - 1
          uri = "file://#{original_path}"
          range = Types::Range.new(
            start_position: Types::Position.new(line: line, character: col),
            end_position: Types::Position.new(line: line, character: col)
          )
          return {uri, range}
        end
      end
      uri = file.starts_with?("file://") ? file : "file://#{file}"
      {uri, loc.to_range}
    end

    # For top-level code (no enclosing def), create a synthetic Def so that
    # build_type_env / TypeCollector can collect local variable types.
    private def effective_scope_def(finder : NodeFinder, document : WorkspaceDocument) : Crystal::Def?
      finder.enclosing_def || file_scope_def(document)
    end

    private def file_scope_def(document : WorkspaceDocument) : Crystal::Def?
      if body = document.program
        Crystal::Def.new("__file__", [] of Crystal::Arg, body)
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
        # Simple getter: 0-param instance method with a return type — show as property.
        if !definition.class_method && definition.min_arity == 0 && definition.max_arity == 0 &&
           (definition.return_type_ref || definition.return_type != "Nil")
          return "#{definition.name} : #{definition.return_type}"
        end
        owner_name = definition.owner.try(&.name) || "self"
        separator = "."
        params = definition.parameters.map_with_index { |name, i|
          if type_ref = definition.param_type_refs[i]?
            "#{name} : #{type_ref.display}"
          else
            name
          end
        }.join(", ")
        signature = "def #{owner_name}#{separator}#{definition.name}"
        signature += "(#{params})" unless params.empty?
        if definition.return_type_ref || definition.return_type != "Nil"
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
      when Psi::LocalVar
        if definition.type.empty?
          definition.name
        else
          "#{definition.name} : #{definition.type}"
        end
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

      collector = NameHighlightCollector.new(name, var: true, arg: true)
      scope_def.body.accept(collector)
      scope_def.args.each do |arg|
        collector.nodes << arg if arg.name == name
      end

      document_highlights_for(collector.nodes)
    end

    private def highlights_for_instance_var(name : String, scope_class : Crystal::ClassDef?) : Array(Types::DocumentHighlight)
      return [] of Types::DocumentHighlight unless scope_class

      collector = NameHighlightCollector.new(name, ivar: true)
      scope_class.body.accept(collector)
      document_highlights_for(collector.nodes)
    end

    private def highlights_for_class_var(name : String, scope_class : Crystal::ClassDef?) : Array(Types::DocumentHighlight)
      return [] of Types::DocumentHighlight unless scope_class

      collector = NameHighlightCollector.new(name, cvar: true)
      scope_class.body.accept(collector)
      document_highlights_for(collector.nodes)
    end

    private def highlights_for_path(path : Crystal::Path, program : Crystal::ASTNode?) : Array(Types::DocumentHighlight)
      return [] of Types::DocumentHighlight unless program

      collector = PathHighlightCollector.new(path.full, path.global?)
      program.accept(collector)
      document_highlights_for(collector.nodes)
    end

    private def references_for_local(name : String, scope_def : Crystal::Def?, uri : String, include_decl : Bool) : Array(Types::Location)
      return [] of Types::Location unless scope_def

      collector = NameHighlightCollector.new(name, var: true, arg: true)
      scope_def.body.accept(collector)
      scope_def.args.each do |arg|
        collector.nodes << arg if arg.name == name
      end
      collector.nodes.reject! { |n| n.is_a?(Crystal::Arg) } unless include_decl
      locations_for_nodes(collector.nodes, uri)
    end

    private def references_for_instance_var(name : String, scope_class : Crystal::ClassDef?, uri : String, include_decl : Bool) : Array(Types::Location)
      return [] of Types::Location unless scope_class

      collector = NameHighlightCollector.new(name, ivar: true)
      scope_class.body.accept(collector)
      locations_for_nodes(collector.nodes, uri)
    end

    private def references_for_class_var(name : String, scope_class : Crystal::ClassDef?, uri : String, include_decl : Bool) : Array(Types::Location)
      return [] of Types::Location unless scope_class

      collector = NameHighlightCollector.new(name, cvar: true)
      scope_class.body.accept(collector)
      locations_for_nodes(collector.nodes, uri)
    end

    private def references_for_method(node : Crystal::ASTNode, finder : NodeFinder, uri : String, include_decl : Bool) : Array(Types::Location)
      definitions = @analyzer.find_definitions(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        uri
      )
      target_keys = method_keys_for(definitions)
      return [] of Types::Location if target_keys.empty?
      references_for_methods_in_workspace(target_keys, include_decl)
    end

    private def references_for_methods_in_workspace(
      target_keys : Hash(String, Bool),
      include_decl : Bool
    ) : Array(Types::Location)
      locations = [] of Types::Location
      seen = {} of String => Bool
      workspace_file_uris.each do |file_uri|
        program = program_for_uri(file_uri)
        next unless program

        collector = MethodRenameCollector.new(@analyzer, file_uri, target_keys)
        program.accept(collector)

        if include_decl
          collector.def_nodes.each do |def_node|
            if range = def_name_range(def_node)
              key = "#{file_uri}:#{range.start_position.line}:#{range.start_position.character}:#{range.end_position.line}:#{range.end_position.character}"
              next if seen[key]?
              seen[key] = true
              locations << Types::Location.new(uri: file_uri, range: range)
            end
          end
        end

        collector.call_nodes.each do |call_node|
          if range = call_name_range(call_node)
            key = "#{file_uri}:#{range.start_position.line}:#{range.start_position.character}:#{range.end_position.line}:#{range.end_position.character}"
            next if seen[key]?
            seen[key] = true
            locations << Types::Location.new(uri: file_uri, range: range)
          end
        end
      end
      locations
    end

    private def references_for_path(full_name : String, global : Bool, program : Crystal::ASTNode?, uri : String) : Array(Types::Location)
      return [] of Types::Location unless program

      collector = PathHighlightCollector.new(full_name, global)
      program.accept(collector)
      locations_for_nodes(collector.nodes, uri)
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

    private def locations_for_nodes(nodes : Array(Crystal::ASTNode), uri : String) : Array(Types::Location)
      locs = [] of Types::Location
      seen = {} of String => Bool
      nodes.each do |node|
        range = node_name_range(node) || node_range(node)
        next unless range
        key = "#{range.start_position.line}:#{range.start_position.character}:#{range.end_position.line}:#{range.end_position.character}"
        next if seen[key]?
        seen[key] = true
        locs << Types::Location.new(uri: uri, range: range)
      end
      locs
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

    private def call_hierarchy_item(element : Psi::PsiElement) : Types::CallHierarchyItem?
      loc = element.location
      file = element.file
      return nil unless loc && file
      uri = file.starts_with?("file://") ? file : "file://#{file}"
      range = loc.to_range
      Types::CallHierarchyItem.new(
        name: element.name,
        kind: symbol_kind_for(element),
        uri: uri,
        range: range,
        selection_range: range,
        detail: element.responds_to?(:owner) ? element.owner.try(&.name) : nil
      )
    end

    private def type_hierarchy_item(element : Psi::PsiElement) : Types::TypeHierarchyItem?
      loc = element.location
      file = element.file
      return nil unless loc && file
      uri = file.starts_with?("file://") ? file : "file://#{file}"
      range = loc.to_range
      Types::TypeHierarchyItem.new(
        name: element.name,
        kind: symbol_kind_for(element),
        uri: uri,
        range: range,
        selection_range: range,
        detail: element.responds_to?(:owner) ? element.owner.try(&.name) : nil
      )
    end

    private def symbol_kind_for(element : Psi::PsiElement) : Types::SymbolKind
      case element
      when Psi::Module
        Types::SymbolKind::Module
      when Psi::Class
        Types::SymbolKind::Class
      when Psi::Enum
        Types::SymbolKind::Enum
      when Psi::Method
        Types::SymbolKind::Method
      when Psi::InstanceVar, Psi::ClassVar
        Types::SymbolKind::Field
      else
        Types::SymbolKind::Object
      end
    end

    # Collects inline value variable lookups within a requested range.
    private class InlineValueCollector < Crystal::Visitor
      getter values : Array(Types::InlineValue)

      def initialize(range : Types::Range)
        @values = [] of Types::InlineValue
        @seen = {} of String => Bool
        @start_line = range.start_position.line
        @start_char = range.start_position.character
        @end_line = range.end_position.line
        @end_char = range.end_position.character
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Var) : Bool
        add_value(node.name, node)
        true
      end

      def visit(node : Crystal::InstanceVar) : Bool
        add_value(node.name, node)
        true
      end

      def visit(node : Crystal::ClassVar) : Bool
        add_value(node.name, node)
        true
      end

      def visit(node : Crystal::Arg) : Bool
        add_value(node.name, node)
        true
      end

      private def add_value(name : String, node : Crystal::ASTNode)
        return if name.empty?
        loc = node.name_location || node.location
        return unless loc

        start_line = loc.line_number - 1
        start_char = loc.column_number - 1
        size = node.name_size
        end_line = loc.line_number - 1
        end_char = start_char + size

        return unless overlaps_range?(start_line, start_char, end_line, end_char)

        range = Types::Range.new(
          start_position: Types::Position.new(line: start_line, character: start_char),
          end_position: Types::Position.new(line: end_line, character: end_char)
        )
        key = "#{name}:#{start_line}:#{start_char}"
        return if @seen[key]?
        @seen[key] = true

        @values << Types::InlineValueVariableLookup.new(
          range: range,
          case_sensitive_lookup: true,
          variable_name: name
        )
      end

      private def overlaps_range?(start_line : Int32, start_char : Int32, end_line : Int32, end_char : Int32) : Bool
        after_end = start_line > @end_line || (start_line == @end_line && start_char > @end_char)
        before_start = end_line < @start_line || (end_line == @start_line && end_char < @start_char)
        !(after_end || before_start)
      end
    end
  end

  class NameHighlightCollector < Crystal::Visitor
    getter nodes : Array(Crystal::ASTNode)

    def initialize(@name : String, @var : Bool = false, @arg : Bool = false, @ivar : Bool = false, @cvar : Bool = false)
      @nodes = [] of Crystal::ASTNode
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Var) : Bool
      @nodes << node if @var && node.name == @name
      true
    end

    def visit(node : Crystal::Arg) : Bool
      @nodes << node if @arg && node.name == @name
      true
    end

    def visit(node : Crystal::InstanceVar) : Bool
      @nodes << node if @ivar && node.name == @name
      true
    end

    def visit(node : Crystal::ClassVar) : Bool
      @nodes << node if @cvar && node.name == @name
      true
    end

    def visit(node : Crystal::Def) : Bool
      true
    end

    def visit(node : Crystal::ClassDef) : Bool
      true
    end

    def visit(node : Crystal::ModuleDef) : Bool
      true
    end

    def visit(node : Crystal::EnumDef) : Bool
      true
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
