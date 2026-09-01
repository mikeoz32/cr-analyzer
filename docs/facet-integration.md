# Facet Integration Status

## Decision

cr-analyzer is moving to Facet as its only syntax frontend. The migration is
incremental so editor features stay available while semantic consumers are
ported from `Crystal::ASTNode` to Facet's native arena-backed AST.

Facet's AST is not expected to match Crystal's AST. Consumers use
`SyntaxTree` / `SyntaxNode`, a stable named-query facade over Facet's own node
roles, spans, and symbols.

## Current boundary

| Concern | Current implementation |
| --- | --- |
| Source versions and query invalidation | Workspace-owned Facet `SourceManager` + `QueryDb` |
| Syntax diagnostics | Cached Facet parse; Crystal diagnostic fallback remains available |
| UTF-8 byte / LSP UTF-16 conversion | Facet `LineIndex` |
| Cursor lookup and selection ranges | Facet `SyntaxTree#node_at` / `FacetNodeFinder` |
| Document/workspace symbols | Facet collector is authoritative; Crystal collector is empty-result fallback |
| Declaration semantic index | Facet primary index for types, methods, aliases, includes, inheritance, enum members, docs, and locations; Crystal retains macro fallback data |
| Completion prefixes, enclosing syntax, keywords | Facet `LineIndex` + `FacetNodeFinder` + named condition roles |
| Receiver/member and named-argument completion | Facet-first named receiver/call/parameter roles; Crystal fallback for unsupported inference shapes |
| Locals and scoped variables | Facet local-name collection and typed/constructor assignment inference, including incomplete buffers |
| Navigation, hover, signature help, type hierarchy | Facet-first semantic resolution; Crystal fallback remains |
| References, rename, document highlights | Facet-first scope-aware occurrence collection; Crystal fallback remains |
| Inline values | Facet syntax plus semantic local classification |
| Call graph | Facet per-file call-site cache plus lazy revision-cached semantic resolution; Crystal fallback for legacy items |
| Macro support | Facet `QueryDb#expand` plus generated-declaration delta is primary for standard declaration macros and supported user macros, including indexed type/member introspection; Crystal interpreter is fallback for remaining APIs |
| Facet-only validation | `CRA_FACET_ONLY=1` disables Crystal AST construction; all workspace LSP specs run against Facet alone in CI |

Each URI has a stable Facet `FileId`. A document version is parsed once and its
`AstFile`, `SyntaxTree`, diagnostics, parent map, and line index are reused by
all syntax consumers. Unchanged source bytes retain the cached query result.
Macro expansion invalidation is footprint-based, so edits to unrelated files
do not force ordinary macro re-expansion. Materialized type-aware consumers use
a conservative workspace-declaration dependency so changed indexed members
cannot leave generated declarations stale.

The server advertises incremental LSP text synchronization and applies UTF-16
range edits before advancing the Facet source revision. Frontend invalidation is
currently file-grained: an edited file is reparsed, but unchanged files and
unrelated macro expansions stay cached.

Project-owned macro consumers are materialized during the initial semantic
pass. Dependency and stdlib consumers remain lazy/legacy until needed; dirty
queues contain only expansions that were actually materialized, preventing an
editor startup from eagerly expanding the entire toolchain.

## Current performance snapshot

On 2026-08-31, a release build initialized against this repository with a
median of 5.797 seconds on the legacy frontend and 3.626 seconds in
`CRA_FACET_ONLY=1` mode (`3` measured runs after `1` warmup), a `1.60x`
speedup. Reproduce the machine-local comparison with
`python3 scripts/bench_lsp_initialize.py`; the result is evidence for the
current architecture, not a fixed CI threshold.

## Completed gates

- Exact Crystal 1.21 parser decision parity on all 4,378 captured upstream
  cases, including exact diagnostics for 941 rejected inputs.
- Exact common semantic AST projection on all 3,437 accepted upstream inputs.
- Clean parse and native AST integrity across all 1,625 Crystal stdlib files.
- Clean parse and native AST integrity across all Facet and cr-analyzer
  source/spec files in the corpus.
- Stable declaration roles, parent/ancestor traversal, cursor lookup, name
  spans, doc comments, and UTF-16 conversion in Facet syntax queries.
- Automatic revision-based parse/syntax/index/expand cache invalidation.
- Tests proving stable file IDs, cache reuse, unrelated-edit expansion reuse,
  macro-provider invalidation, and UTF-16 incremental edits.
- Facet/Crystal document-symbol contract parity for representative nested
  declarations, methods, enum members, and fields.
- A Facet-native two-pass declaration semantic producer plus representative
  parity for types, methods, aliases, includes, inheritance, enum members, docs,
  locations, nested names, and reopen-file invalidation.
- The reusable `scripts/check_facet_semantic_parity.cr` corpus gate; the current
  cr-analyzer source/spec corpus is exact on 68/68 Crystal-accepted files, with
  one additional Facet recovery from a Crystal-rejected file.
- Tested document-symbol and selection-range behavior on incomplete buffers
  rejected by Crystal::Parser.
- Facet-backed completion prefixes, enclosing type context, and keyword-context
  classification, including incomplete conditions and astral UTF-16 positions.
- Facet-first receiver/member and named-argument completion, including typed and
  constructor-assigned locals, chained generic returns, local names, and
  instance/class variables in buffers rejected by Crystal::Parser.
- Facet block-call roles and collection yield inference for common Array, Hash,
  indexed collection, and fluent-call patterns.
- Facet-first declaration/type/implementation navigation, hover, signature help,
  references, rename, highlights, document/workspace symbols, and type hierarchy,
  with regression tests that explicitly remove the Crystal AST.
- Facet-native inline-value collection for parameters, locals, and scoped vars.
- Facet-native incoming/outgoing call hierarchy with per-file extraction, lazy
  edge caching, edit invalidation, cross-file typed receivers, constructors,
  class methods, `super`, and authoritative empty results in buffers rejected
  by Crystal::Parser.
- Ordinary and bare user macro calls resolve by lexical scope and arity in
  Facet; standard accessor families and `record` have Facet-native lowering.
  Macro arguments outside the evaluator subset remain source-backed AST values,
  so generic types and nested expressions survive generated declarations.
  Source-backed macro blocks support `yield`, `block.body`, and `block.args`,
  with block content included in incremental expansion cache keys. Evaluated
  collections support lexical map/select/predicate/iteration blocks used by
  declaration-generating macro control flow.
- Macro strings, symbols, identifiers, and opaque AST arguments retain distinct
  source rendering and scalar values; direct interpolation, `id`, `stringify`,
  `symbolize`, and basic AST predicates no longer erase Crystal syntax roles.
- Facet-native type-aware macro values expose lexical `@type`, indexed
  `resolve`/`resolve?`, methods, instance variables, constants, method/argument
  metadata, explicit superclasses/ancestors, kind predicates, and subtype
  checks. Types, methods, instance variables, and arguments also expose
  annotations with positional and named values. Declaration and annotation
  edits invalidate and requeue materialized type-aware expansion consumers.
- Facet's committed Crystal 1.21 runtime macro corpus captures all 1,017
  contracts executed by the official evaluator specs and matches exact output
  for 517/900 portable contracts, including all 371 self-contained contracts.
  Captured AST values retain start/end locations and documentation. The
  remaining 383 portable mismatches, 117 program-context contracts, and 133
  semantic examples remain explicit and are not counted as passing.
- Expanded Facet ASTs feed generated-only semantic slices, including completion,
  navigation, and call hierarchy in Crystal-rejected buffers. Macro-provider
  edits reindex only the footprint-invalidated consumer files.
- The complete workspace LSP contract runs with no Crystal AST: 101/101 examples
  cover completion, navigation, diagnostics/lints, symbols, references, rename,
  inline values, call/type hierarchy, macro-generated declarations, and
  dependent reindexing.
- Facet infers generic return substitution for user-defined index operators and
  owns unused method/block argument diagnostics.
- Facet include/superclass dependencies drive incremental invalidation and are
  verified through public declaration results before and after provider edits.

## Remaining cutover work

1. Extend Facet inference across the remaining literal, implicit-call, destructure,
   and control-flow shapes, then retire the completion fallback.
2. Extend call-graph differential coverage across overloads, dynamic receivers,
   and representative workspaces, then retire its legacy Crystal fallback.
3. Compare Facet-first public LSP results on stdlib and representative
   workspaces, not only focused declaration contracts.
4. Extend Facet macro evaluation across contextual generic/union type metadata,
   the remaining compiler-backed AST-node/error APIs, require-aware provider
   visibility, and semantic macro cases; then remove the cr-analyzer interpreter
   and all `compiler/crystal/syntax` requires.

Run the local declaration gate after semantic changes:

```console
crystal run scripts/check_facet_semantic_parity.cr
```

Run the LSP cutover gate without constructing any Crystal AST:

```console
CRA_FACET_ONLY=1 crystal spec spec/cra/workspace
```

After a release build, compare end-to-end initialization with and without the
temporary Crystal frontend:

```console
python3 scripts/bench_lsp_initialize.py --repeat 3
```

Local release-build baseline on 2026-08-30, scanning this repository and the
installed stdlib after one warmup per mode (three alternating samples): legacy
initialization was 6.180-7.021 s, median 6.400 s; Facet-only was 3.516-4.758 s,
median 3.637 s. The median improvement was 1.76x. Treat these as local
orientation rather than portable throughput; the script reports every sample
so changes can be compared under the same environment.

## Ownership

Facet owns source text, revisions, lexing, parsing, syntax diagnostics, native
AST queries, macro expansion, and expansion provenance. cr-analyzer owns LSP
transport, workspace policy, the editor semantic model, and protocol results.
