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

    def initialize
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
      expanded = @expansion_queries.expand(file_id)
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

    private def update_expansion(uri : String, text : String) : Nil
      if file_id = @expansion_files_by_uri[uri]?
        @expansion_queries.update(file_id, text)
      end
    end
  end
end
