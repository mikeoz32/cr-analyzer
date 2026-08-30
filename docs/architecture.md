# Architecture

This document describes the major runtime pieces and the request flow.

## Components

- `CRA::JsonRPC::Server`: stdio transport, reads/writes LSP JSON-RPC.
- `CRA::JsonRPC::Processor`: dispatches requests; owns a `Workspace`.
- `CRA::Workspace`: manages documents, indexing, completions, definitions, references, diagnostics.
- `CRA::FacetDocumentStore`: workspace-owned Facet sources and incremental queries.
- `CRA::WorkspaceDocument`: stores text, cached Facet syntax, temporary Crystal AST, and diagnostics.
- `CRA::Psi::SemanticIndex`: semantic database for types, methods, vars, aliases, enums; call graph.
- `CRA::Psi::FacetSemanticIndexer`: Facet-native declaration producer backing
  the primary completion/navigation `SemanticIndex`.
- `CRA::FacetCallGraphIndex`: per-file Facet call-site cache with lazy semantic
  edge resolution and revision invalidation.
- Facet 0.1.5 `QueryDb` / `SyntaxTree`: revisioned syntax, diagnostics, cursor,
  document-symbol, and editor-position queries.
- Completion providers: `SemanticIndex`, `KeywordCompletionProvider`, `RequirePathCompletionProvider`.
- `DocumentSymbolsIndex`: AST visitor for document/workspace symbols.

## Request flow

1. Initialize -> Workspace.scan -> parse and index project, lib, and stdlib files.
2. didOpen/didChange/didSave -> update document text -> parse -> Workspace.reindex_file.
3. selection ranges -> FacetNodeFinder -> Facet syntax spans.
4. completion -> FacetNodeFinder for prefixes, enclosing/keyword context,
   receiver/call roles, and local/scoped-variable inference -> CompletionContext
   -> providers; legacy NodeFinder handles unsupported inference shapes.
5. definition/declaration/implementation/typeDefinition/hover/signature help ->
   FacetNodeFinder -> Facet semantic resolution; legacy resolution is fallback.
6. references/rename/highlights -> Facet symbol occurrence collector; legacy
   Crystal visitors are fallback.
7. type hierarchy and inline values -> Facet; call hierarchy -> Facet call-site
   cache and lazy semantic resolution, with legacy edges as a measured fallback.
8. diagnostics -> cached Facet parse + local lints -> publish/pull; Crystal::Parser is the fallback.

## Indexing and updates

- Incremental LSP text sync (`TextDocumentSyncKind::Incremental`) with UTF-16
  ranges converted by Facet's `LineIndex`.
- Each changed document state advances one Facet source revision. Parse and
  syntax queries are cached; identical updates reuse the existing results.
- Call-site extraction replaces only the edited file's slice. Resolved call
  edges are computed on demand, reused for an unchanged workspace revision, and
  invalidated globally when declarations or call sites change.
- Crystal::Parser still parses each changed document while semantic consumers
  are being migrated.
- Reindexing also reindexes dependent types based on include/extend and superclass relationships.
- stdlib lookup uses CRYSTAL_PATH or CRYSTAL_HOME, with /usr/share/crystal/src as fallback.

## Parser boundary

The server currently maintains two syntax paths during cutover:

- Facet owns source revisions, parsing, diagnostics, `SyntaxTree`,
  `FacetNodeFinder`, selection ranges, document/workspace symbols, and the primary
  declaration semantic producer. It also owns completion syntax and common
  inference plus navigation, references, rename, highlights, and type hierarchy.
- Crystal::Parser produces the temporary `Crystal::ASTNode` tree consumed by
  macro expansion, unsupported completion inference fallback, and remaining
  SemanticIndex consumers.

Facet's AST remains native and arena-backed; cr-analyzer consumes its stable
named query API rather than a Crystal AST compatibility layer. The Crystal path
will be removed feature by feature after differential result gates pass.

Incrementality is currently file-grained: unchanged files and unchanged text
reuse query results, while an edited file is lexed and parsed again. Subtree-level
incremental parsing can be added later without changing the workspace/query API.
