# AGENTS

This file is for contributors and automation agents working on this repo.

## Project summary

cr-analyzer is a lightweight LSP server for Crystal. It builds an editor-oriented
semantic index without invoking the full compiler. Facet 0.1.5 now provides a
workspace-owned incremental syntax database, diagnostics, cursor lookup,
selection ranges, document-symbol shadow/fallback results, and a declaration-level
semantic shadow index. Crystal::Parser still provides the AST used by the
remaining navigation and semantic features.

## Setup

- Requires Crystal >= 1.18.2 and shards.
- Install deps: shards install
- Run: crystal run src/bin/cra.cr
- Build: shards build (binary at bin/cr-analyzer)
- Tests: crystal spec
- End-to-end LSP test: uv run pytest
- Facet semantic parity: crystal run scripts/check_facet_semantic_parity.cr
- Manual client: uv run main.py (uses the Python env in pyproject.toml)

## Repo layout

- src/cr-analyzer.cr: JSON-RPC server and request handlers.
- src/bin/cra.cr: server entry point.
- src/cra/workspace.cr: workspace scan, incremental reindexing, and LSP feature routing.
- src/cra/workspace/: document model, NodeFinder, rename, symbols, and completion providers.
- src/cra/semantic/: SemanticIndex, indexing passes, TypeRef.
- src/cra/analysis/: macro expansion helpers (MacroExpander/MacroInterpreter).
- src/cra/types.cr: LSP types and protocol classes.
- spec/: specs.
- tests/: Python end-to-end LSP test.

## Data flow

- Initialize -> Workspace.scan -> parse and index workspace, dependencies, and stdlib.
- didOpen/didChange/didSave -> incremental LSP text edits -> revisioned Facet
  query plus temporary Crystal parse -> reindex the file and dependent types.
- completion -> NodeFinder -> CompletionContext -> providers.
- navigation/references/hierarchies -> NodeFinder -> SemanticIndex.
- diagnostics -> Facet parser diagnostics + local lint checks -> push or pull response.

## Semantic Index notes

- Two passes: SkeletonIndexer (type shells) and SemanticIndexer (methods/includes/enums/aliases).
- TypeRef is lightweight: name + generic args + union types. Inference is best-effort (annotations, Foo.new, Array/Hash literals with of).
- Macro expansion is limited; expanded code is indexed under crystal-macro: URIs.

## Parser boundary

- `WorkspaceDocument#program` and the remaining semantic consumers use `Crystal::ASTNode`.
- Facet uses stable per-URI file IDs in a workspace-owned `QueryDb`; do not
  reparse Facet locally or discard its `SyntaxTree`.
- Facet owns diagnostic spans, UTF-16 conversion, selection ranges, and the
  document-symbol fallback for incomplete buffers.
- Facet's declaration-level semantic producer runs in shadow mode for types,
  methods, aliases, includes, inheritance, enum members, docs, and locations.
- `CRA_DISABLE_FACET_DIAGNOSTICS=1` switches diagnostics back to Crystal::Parser.
- Facet's native AST is intentionally different from Crystal's AST. Extend its
  `SyntaxTree` / `SyntaxNode` query facade instead of emulating Crystal nodes or
  depending on raw child positions in cr-analyzer.
- Port remaining features through shadow result parity before removing their
  Crystal::Parser fallback.

## Environment

- CRYSTAL_PATH or CRYSTAL_HOME controls stdlib scan; fallback is /usr/share/crystal/src.
- CRA_DUMP_ROOTS=1 logs index roots on scan.
- CRA_SKIP_STDLIB_SCAN=1 skips stdlib indexing for focused tests/debugging.
- CRA_DISABLE_FACET_DIAGNOSTICS=1 disables Facet diagnostics.

## LSP status

- Implemented: full-text sync, completion/resolve, declaration/definition/type
  definition/implementation, hover, signature help, references, rename,
  document/workspace symbols, diagnostics, document highlights, selection ranges,
  inline values, and call/type hierarchies.
- Planned: semantic tokens, code actions/lens, folding ranges, formatting, document
  links, inlay hints, and monikers.
- Keep README, docs/roadmap.md, handlers, tests, and ServerCapabilities in sync.
