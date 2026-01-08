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
  end
end
