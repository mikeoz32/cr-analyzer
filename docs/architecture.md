# Architecture

This document describes the major runtime pieces and the request flow.

## Components

- `CRA::JsonRPC::Server`: stdio transport, reads/writes LSP JSON-RPC.
- `CRA::JsonRPC::Processor`: dispatches requests; owns a `Workspace`.
- `CRA::Workspace`: manages documents, indexing, completions, definitions, references, diagnostics.
- `CRA::FacetDocumentStore`: workspace-owned Facet sources and incremental queries.
- `CRA::WorkspaceDocument`: stores text, cached Facet syntax, optional temporary Crystal AST, and diagnostics.
- `CRA::Psi::SemanticIndex`: semantic database for types, methods, vars, aliases, enums; call graph.
- `CRA::Psi::FacetSemanticIndexer`: Facet-native declaration producer backing
  the primary completion/navigation `SemanticIndex`.
- `CRA::FacetCallGraphIndex`: per-file Facet call-site cache with lazy semantic
  edge resolution and revision invalidation.
- Facet expanded declaration slices: cached `QueryDb#expand` results are diffed
  against raw syntax and indexed under stable `facet-macro:` URIs.
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
8. diagnostics -> cached Facet parse + Facet-native local lints -> publish/pull;
   Crystal::Parser is the explicit fallback outside Facet-only mode.

## Indexing and updates

- Incremental LSP text sync (`TextDocumentSyncKind::Incremental`) with UTF-16
  ranges converted by Facet's `LineIndex`.
- Each changed document state advances one Facet source revision. Parse and
  syntax queries are cached; identical updates reuse the existing results.
- Call-site extraction replaces only the edited file's slice. Resolved call
  edges are computed on demand, reused for an unchanged workspace revision, and
  invalidated globally when declarations or call sites change.
- Macro provider edits invalidate only expansion consumers recorded in Facet's
  macro-name footprint. Their old virtual semantic slices are removed before
  generated declaration deltas are reindexed.
- Initial eager expansion is limited to project-owned sources. Dependency and
  stdlib macro declarations remain on the lazy/legacy path until requested, so
  initialization does not expand thousands of unrelated files. A separate
  materialized expansion `QueryDb` keeps this provider set independent from the
  complete syntax database.
- Crystal::Parser still parses each changed document while semantic consumers
  are being migrated, unless `CRA_FACET_ONLY=1` selects the CI cutover lane.
- Facet include/extend and superclass relationships drive dependent-file
  invalidation. Legacy relationships remain only for legacy index refreshes.
- stdlib lookup uses CRYSTAL_PATH or CRYSTAL_HOME, with /usr/share/crystal/src as fallback.

## Parser boundary

The server currently maintains two syntax paths during cutover:

- Facet owns source revisions, parsing, diagnostics, `SyntaxTree`,
  `FacetNodeFinder`, selection ranges, document/workspace symbols, and the primary
  declaration semantic producer. It also owns completion syntax and common
  inference plus navigation, references, rename, highlights, type hierarchy,
  call graph, and supported macro-generated declarations.
- Crystal::Parser produces the temporary `Crystal::ASTNode` tree consumed by
  unsupported type-aware macro expansion, completion inference fallback, and
  remaining SemanticIndex consumers.

Facet's AST remains native and arena-backed; cr-analyzer consumes its stable
named query API rather than a Crystal AST compatibility layer. The Crystal path
will be removed feature by feature after differential result gates pass.

`CRA_FACET_ONLY=1 crystal spec spec/cra/workspace` is the executable boundary:
the full workspace LSP suite must pass while `WorkspaceDocument#program` stays
nil. This prevents apparently successful Facet results from silently depending
on a Crystal parser fallback.

`scripts/bench_lsp_initialize.py` measures the same release binary and workspace
with both frontend modes, warms each mode, and alternates sample order to reduce
filesystem-cache bias. Keep the per-run range alongside the median when using
it to justify a default-mode change.

Incrementality is currently file-grained: unchanged files and unchanged text
reuse query results, while an edited file is lexed and parsed again. Subtree-level
incremental parsing can be added later without changing the workspace/query API.
