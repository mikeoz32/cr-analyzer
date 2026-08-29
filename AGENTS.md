# AGENTS

This file is for contributors and automation agents working on this repo.

## Project summary

cr-analyzer is a lightweight LSP server for Crystal. It builds an editor-oriented
semantic index without invoking the full compiler. Crystal::Parser currently
provides the AST used by navigation and semantic features; Facet 0.1.5 provides
the default parser diagnostics.

## Setup

- Requires Crystal >= 1.18.2 and shards.
- Install deps: shards install
- Run: crystal run src/bin/cra.cr
- Build: shards build (binary at bin/cr-analyzer)
- Tests: crystal spec
- End-to-end LSP test: uv run pytest
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
- didOpen/didChange/didSave -> WorkspaceDocument update -> parse -> reindex the file and dependent types.
- completion -> NodeFinder -> CompletionContext -> providers.
- navigation/references/hierarchies -> NodeFinder -> SemanticIndex.
- diagnostics -> Facet parser diagnostics + local lint checks -> push or pull response.

## Semantic Index notes

- Two passes: SkeletonIndexer (type shells) and SemanticIndexer (methods/includes/enums/aliases).
- TypeRef is lightweight: name + generic args + union types. Inference is best-effort (annotations, Foo.new, Array/Hash literals with of).
- Macro expansion is limited; expanded code is indexed under crystal-macro: URIs.

## Parser boundary

- `WorkspaceDocument#program`, NodeFinder, and the semantic index use `Crystal::ASTNode`.
- Facet 0.1.5 is parsed separately for diagnostics and error recovery.
- `CRA_DISABLE_FACET_DIAGNOSTICS=1` switches diagnostics back to Crystal::Parser.
- Do not assume that a successful Facet parse is already used for semantic features.
- A deeper Facet integration should start behind an adapter or parallel index and
  retain Crystal::Parser as a correctness fallback until compatibility is measured.

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
