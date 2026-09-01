# AGENTS

This file is for contributors and automation agents working on this repo.

## Project summary

cr-analyzer is a lightweight LSP server for Crystal. It builds an editor-oriented
semantic index without invoking the full compiler. Facet 0.1.5 now provides a
workspace-owned incremental syntax database, diagnostics, cursor lookup,
selection ranges, document/workspace symbols, and the primary declaration-level
semantic index. Facet owns completion syntax and common inference, navigation,
hover, signature help, references, rename, highlights, and type hierarchy,
including error-tolerant buffers rejected by Crystal::Parser. Facet also owns
the first type-aware macro slice (`@type`, type resolution, members, constants,
explicit ancestry, and annotation metadata). Facet's committed Crystal 1.21
runtime corpus gates 517/900 portable contracts executed by the official
evaluator specs, including all 371 self-contained contracts, and separately
tracks 117 program-context contracts. The Crystal path remains an explicit
fallback for contextual compiler/type macro APIs, unsupported inference shapes,
and semantic consumers.

## Setup

- Requires Crystal >= 1.18.2 and shards.
- Install deps: shards install
- Run: crystal run src/bin/cra.cr
- Build: shards build (binary at bin/cr-analyzer)
- Tests: crystal spec
- Facet-only workspace contract: CRA_FACET_ONLY=1 crystal spec spec/cra/workspace
- End-to-end LSP test: uv run pytest
- Facet semantic parity: crystal run scripts/check_facet_semantic_parity.cr
- Facet upstream macro parity: `(cd ../facet && crystal run scripts/check_upstream_macro_parity.cr)`
- Facet executed macro parity: `(cd ../facet && crystal run scripts/check_upstream_macro_runtime_parity.cr)`
- Initialize benchmark: python3 scripts/bench_lsp_initialize.py
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
  query plus optional temporary Crystal parse -> reindex the file and dependent
  types from Facet include/superclass edges.
- completion -> FacetNodeFinder for prefixes, enclosing/keyword context,
  receiver/call roles, and local/scoped-variable inference -> CompletionContext
  -> providers; legacy NodeFinder remains a fallback for unsupported shapes.
- navigation/hover/signature/references/rename/type hierarchy -> FacetNodeFinder
  -> Facet semantic index/occurrence collector; legacy NodeFinder is fallback.
- call hierarchy edges -> per-file Facet call-site cache -> lazy revision-cached
  semantic resolution; legacy Crystal edges are fallback only for legacy items.
- macro expansion -> Facet `QueryDb#expand` -> generated-declaration delta under
  `facet-macro:` URIs -> primary Facet semantic index; the legacy interpreter
  covers the remaining unsupported type-aware APIs during cutover. Supported user macro
  blocks preserve caller AST through `yield`, `block.body`, and `block.args`;
  collection macro blocks keep their own parameters and propagate outer values.
- diagnostics -> Facet parser diagnostics + local lint checks -> push or pull response.

## Semantic Index notes

- Two passes: SkeletonIndexer (type shells) and SemanticIndexer (methods/includes/enums/aliases).
- TypeRef is lightweight: name + generic args + union types. Inference is best-effort (annotations, Foo.new, Array/Hash literals with of).
- Facet expands standard declaration macros and the supported user-macro subset;
  generated declarations are indexed under `facet-macro:` URIs. Unsupported
  AST arguments are preserved as source-backed values. Facet-native type-aware
  values cover lexical `@type`, indexed `resolve`, members, constants, explicit
  ancestry, annotations on types/methods/instance variables/arguments, and
  captured AST locations/documentation;
  remaining expansions stay under `crystal-macro:` URIs. Preserve the distinction
  between macro source rendering and scalar values when extending evaluation.

## Parser boundary

- `WorkspaceDocument#program` is a temporary fallback used by the remaining
  Crystal semantic consumers; Facet features must continue to work when it is nil.
- Facet uses stable per-URI file IDs in a workspace-owned `QueryDb`; do not
  reparse Facet locally or discard its `SyntaxTree`.
- Facet owns diagnostic spans, UTF-16 conversion, selection ranges, and
  document/workspace symbols.
- Completion line prefixes, enclosing type names, and keyword context come from
  Facet byte spans and UTF-16 conversion, including incomplete buffers.
- Completion consumes Facet's named receiver, callee, arguments, named arguments,
  parameter type/default, assignment, and variable roles. Keep Crystal fallback
  explicit until unsupported inference forms have differential coverage.
- Facet's declaration-level semantic producer is the primary completion and
  navigation index for types, methods, aliases, includes, inheritance, enum
  members, docs, and locations. Keep the Crystal index as a measured fallback
  until type-aware macro APIs and the remaining semantic consumers move.
- Facet expansion consumers are invalidated from macro-name/required-file
  footprints. Consumers that use type introspection additionally depend on the
  workspace declaration revision. Reindex `pending_expansion_file_ids` only,
  remove the stable virtual-file slice first, and index only the generated
  declaration delta rather than duplicating the full expanded source.
- Keep macro expansion in the materialized project/on-demand QueryDb; do not
  make editor initialization build a global expansion index over stdlib and
  `lib` sources.
- Facet call-graph extraction is file-grained. Preserve call sites for unchanged
  files and invalidate the lazily resolved edge set when any indexed file
  revision changes; an authoritative empty Facet result must not fall back to a
  stale Crystal edge.
- `CRA_DISABLE_FACET_DIAGNOSTICS=1` switches diagnostics back to Crystal::Parser.
- `CRA_FACET_ONLY=1` disables Crystal AST construction. Keep the complete
  `spec/cra/workspace` suite green in this mode; do not weaken an empty Facet
  result into an implicit legacy fallback.
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
- CRA_FACET_ONLY=1 disables Crystal parsing for the workspace contract lane.

## LSP status

- Implemented: full-text sync, completion/resolve, declaration/definition/type
  definition/implementation, hover, signature help, references, rename,
  document/workspace symbols, diagnostics, document highlights, selection ranges,
  inline values, and call/type hierarchies.
- Planned: semantic tokens, code actions/lens, folding ranges, formatting, document
  links, inlay hints, and monikers.
- Keep README, docs/roadmap.md, handlers, tests, and ServerCapabilities in sync.
