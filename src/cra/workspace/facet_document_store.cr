require "facet/compiler"
require "uri"

module CRA
  record FacetDocumentSnapshot,
    file_id : Facet::Compiler::FileId,
    syntax : Facet::Compiler::SyntaxTree,
    changed : Bool

  # Workspace-owned incremental Facet database. Documents retain stable file
  # IDs across edits, and every syntax consumer shares the same parse caches.
  # Macro expansion uses a second query database containing only materialized
  # project/on-demand sources, avoiding a global stdlib expansion index at
  # editor startup while preserving exact provider invalidation for that set.
  class FacetDocumentStore
    getter manager : Facet::Compiler::SourceManager
    getter queries : Facet::Compiler::QueryDb
    getter expansion_queries : Facet::Compiler::QueryDb
    getter macro_context : Facet::Compiler::MacroExpansionContext

    def initialize(
      @macro_context : Facet::Compiler::MacroExpansionContext = FacetDocumentStore.build_target_macro_context,
    )
      @manager = Facet::Compiler::SourceManager.new
      @queries = Facet::Compiler::QueryDb.new(@manager)
      @expansion_manager = Facet::Compiler::SourceManager.new
      @expansion_queries = Facet::Compiler::QueryDb.new(@expansion_manager)
      @files_by_uri = {} of String => Facet::Compiler::FileId
      @expansion_files_by_uri = {} of String => Facet::Compiler::FileId
      @expansion_uris_by_file = {} of Facet::Compiler::FileId => String
      @expanded_arenas = {} of String => Facet::Compiler::AstArena
      @expanded_trees = {} of String => Facet::Compiler::SyntaxTree
    end

    # Registers workspace/dependency files without forcing a parse. This keeps
    # scans cheap while making the complete source set available to later
    # cross-file index and macro queries.
    def register(uri : String, text : String, filename : String) : Facet::Compiler::FileId
      if file_id = @files_by_uri[uri]?
        @queries.update(file_id, text)
        update_expansion(uri, text)
        return file_id
      end

      file_id, _ = @queries.upsert(text, filename)
      @files_by_uri[uri] = file_id
      file_id
    end

    def update(uri : String, text : String, filename : String) : FacetDocumentSnapshot
      file_id : Facet::Compiler::FileId
      changed : Bool
      if existing = @files_by_uri[uri]?
        file_id = existing
        changed = @queries.update(file_id, text)
        update_expansion(uri, text)
      else
        file_id, changed = @queries.upsert(text, filename)
        @files_by_uri[uri] = file_id
      end
      FacetDocumentSnapshot.new(file_id, @queries.syntax(file_id), changed)
    end

    def syntax(uri : String) : Facet::Compiler::SyntaxTree?
      @files_by_uri[uri]?.try { |file_id| @queries.syntax(file_id) }
    end

    def expanded_syntax(uri : String) : Facet::Compiler::SyntaxTree?
      file_id = enable_expansion(uri)
      return nil unless file_id
      original = @expansion_queries.parse(file_id)
      expanded = @expansion_queries.expand(file_id, @macro_context)
      return nil if expanded.arena.same?(original.arena)

      if arena = @expanded_arenas[uri]?
        return @expanded_trees[uri]? if arena.same?(expanded.arena)
      end
      tree = Facet::Compiler::SyntaxTree.new(expanded)
      @expanded_arenas[uri] = expanded.arena
      @expanded_trees[uri] = tree
      tree
    end

    def enable_expansion(uri : String) : Facet::Compiler::FileId?
      if expansion_file_id = @expansion_files_by_uri[uri]?
        return expansion_file_id
      end
      source_file_id = @files_by_uri[uri]?
      return nil unless source_file_id
      source = @manager.source(source_file_id)
      filename = source.filename || URI.parse(uri).path
      file_id, _ = @expansion_queries.upsert(source.text, filename)
      @expansion_files_by_uri[uri] = file_id
      @expansion_uris_by_file[file_id] = uri
      file_id
    end

    def file_id(uri : String) : Facet::Compiler::FileId?
      @files_by_uri[uri]?
    end

    def revision(uri : String) : UInt64?
      @files_by_uri[uri]?.try { |file_id| @manager.revision(file_id) }
    end

    def uris : Array(String)
      @files_by_uri.keys
    end

    def pending_expansion_uris : Array(String)
      @expansion_queries.pending_expansion_file_ids.compact_map { |file_id| @expansion_uris_by_file[file_id]? }
    end

    # Macro `flag?` observes the target used to build cr-analyzer. A future
    # target-selection setting can inject another explicit context through the
    # constructor without changing Facet's cache semantics.
    def self.build_target_macro_context : Facet::Compiler::MacroExpansionContext
      flags = [] of String
      {% if flag?(:x86_64) %}
        flags << "x86_64"
      {% end %}
      {% if flag?(:i386) %}
        flags << "i386"
      {% end %}
      {% if flag?(:aarch64) %}
        flags << "aarch64"
      {% end %}
      {% if flag?(:arm) %}
        flags << "arm"
      {% end %}
      {% if flag?(:bits64) %}
        flags << "bits64"
      {% end %}
      {% if flag?(:bits32) %}
        flags << "bits32"
      {% end %}
      {% if flag?(:pc) %}
        flags << "pc"
      {% end %}
      {% if flag?(:linux) %}
        flags << "linux"
      {% end %}
      {% if flag?(:darwin) %}
        flags << "darwin"
      {% end %}
      {% if flag?(:freebsd) %}
        flags << "freebsd"
      {% end %}
      {% if flag?(:openbsd) %}
        flags << "openbsd"
      {% end %}
      {% if flag?(:netbsd) %}
        flags << "netbsd"
      {% end %}
      {% if flag?(:dragonfly) %}
        flags << "dragonfly"
      {% end %}
      {% if flag?(:solaris) %}
        flags << "solaris"
      {% end %}
      {% if flag?(:android) %}
        flags << "android"
      {% end %}
      {% if flag?(:windows) %}
        flags << "windows"
      {% end %}
      {% if flag?(:win32) %}
        flags << "win32"
      {% end %}
      {% if flag?(:unix) %}
        flags << "unix"
      {% end %}
      {% if flag?(:wasm32) %}
        flags << "wasm32"
      {% end %}
      {% if flag?(:wasi) %}
        flags << "wasi"
      {% end %}
      {% if flag?(:gnu) %}
        flags << "gnu"
      {% end %}
      {% if flag?(:musl) %}
        flags << "musl"
      {% end %}
      {% if flag?(:msvc) %}
        flags << "msvc"
      {% end %}
      {% if flag?(:strict_multi_assign) %}
        flags << "strict_multi_assign"
      {% end %}
      {% if flag?(:preview_mt) %}
        flags << "preview_mt"
      {% end %}
      {% if flag?(:execution_context) %}
        flags << "execution_context"
      {% end %}
      Facet::Compiler::MacroExpansionContext.new(flags: flags)
    end

    private def update_expansion(uri : String, text : String) : Nil
      if file_id = @expansion_files_by_uri[uri]?
        @expansion_queries.update(file_id, text)
      end
    end
  end
end
