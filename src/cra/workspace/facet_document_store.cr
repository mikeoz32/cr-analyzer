require "facet/compiler"

module CRA
  record FacetDocumentSnapshot,
    file_id : Facet::Compiler::FileId,
    syntax : Facet::Compiler::SyntaxTree,
    changed : Bool

  # Workspace-owned incremental Facet database. Documents retain stable file
  # IDs across edits, and every consumer shares the same parse/syntax caches.
  class FacetDocumentStore
    getter manager : Facet::Compiler::SourceManager
    getter queries : Facet::Compiler::QueryDb

    def initialize
      @manager = Facet::Compiler::SourceManager.new
      @queries = Facet::Compiler::QueryDb.new(@manager)
      @files_by_uri = {} of String => Facet::Compiler::FileId
    end

    # Registers workspace/dependency files without forcing a parse. This keeps
    # scans cheap while making the complete source set available to later
    # cross-file index and macro queries.
    def register(uri : String, text : String, filename : String) : Facet::Compiler::FileId
      if file_id = @files_by_uri[uri]?
        @queries.update(file_id, text)
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
      else
        file_id, changed = @queries.upsert(text, filename)
        @files_by_uri[uri] = file_id
      end
      FacetDocumentSnapshot.new(file_id, @queries.syntax(file_id), changed)
    end

    def syntax(uri : String) : Facet::Compiler::SyntaxTree?
      @files_by_uri[uri]?.try { |file_id| @queries.syntax(file_id) }
    end

    def file_id(uri : String) : Facet::Compiler::FileId?
      @files_by_uri[uri]?
    end
  end
end
