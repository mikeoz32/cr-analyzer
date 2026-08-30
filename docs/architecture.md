# Architecture

This document describes the major runtime pieces and the request flow.

## Components

- `CRA::JsonRPC::Server`: stdio transport, reads/writes LSP JSON-RPC.
- `CRA::JsonRPC::Processor`: dispatches requests; owns a `Workspace`.
- `CRA::Workspace`: manages documents, indexing, completions, definitions, references, diagnostics.
- `CRA::FacetDocumentStore`: workspace-owned Facet sources and incremental queries.
- `CRA::WorkspaceDocument`: stores text, cached Facet syntax, temporary Crystal AST, and diagnostics.
- `CRA::Psi::SemanticIndex`: semantic database for types, methods, vars, aliases, enums; call graph.
- `CRA::Psi::FacetSemanticIndexer`: Facet-native declaration producer running
  against a separate shadow `SemanticIndex` during result-parity work.
- Facet 0.1.5 `QueryDb` / `SyntaxTree`: revisioned syntax, diagnostics, cursor,
  document-symbol, and editor-position queries.
- Completion providers: `SemanticIndex`, `KeywordCompletionProvider`, `RequirePathCompletionProvider`.
- `DocumentSymbolsIndex`: AST visitor for document/workspace symbols.

## Request flow

1. Initialize -> Workspace.scan -> parse and index project, lib, and stdlib files.
2. didOpen/didChange/didSave -> update document text -> parse -> Workspace.reindex_file.
3. selection ranges -> FacetNodeFinder -> Facet syntax spans.
4. completion -> legacy NodeFinder -> CompletionContext -> providers -> merged items.
5. definition/declaration/implementation/typeDefinition -> legacy NodeFinder -> SemanticIndex.find_definitions.
6. references -> legacy NodeFinder -> Workspace/SemanticIndex references.
7. call hierarchy -> SemanticIndex call graph.
8. diagnostics -> cached Facet parse + local lints -> publish/pull; Crystal::Parser is the fallback.

## Indexing and updates

- Incremental LSP text sync (`TextDocumentSyncKind::Incremental`) with UTF-16
  ranges converted by Facet's `LineIndex`.
- Each changed document state advances one Facet source revision. Parse and
  syntax queries are cached; identical updates reuse the existing results.
- Crystal::Parser still parses each changed document while semantic consumers
  are being migrated.
- Reindexing also reindexes dependent types based on include/extend and superclass relationships.
- stdlib lookup uses CRYSTAL_PATH or CRYSTAL_HOME, with /usr/share/crystal/src as fallback.

## Parser boundary

The server currently maintains two syntax paths during cutover:

- Facet owns source revisions, parsing, diagnostics, `SyntaxTree`,
  `FacetNodeFinder`, selection ranges, document-symbol fallback, and a shadow
  declaration semantic producer.
- Crystal::Parser produces the temporary `Crystal::ASTNode` tree consumed by
  completion, navigation, rename, and SemanticIndex.

Facet's AST remains native and arena-backed; cr-analyzer consumes its stable
named query API rather than a Crystal AST compatibility layer. The Crystal path
will be removed feature by feature after differential result gates pass.

Incrementality is currently file-grained: unchanged files and unchanged text
reuse query results, while an edited file is lexed and parsed again. Subtree-level
incremental parsing can be added later without changing the workspace/query API.
