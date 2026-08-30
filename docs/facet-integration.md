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
| Macro support | Facet `QueryDb#expand` plus generated-declaration delta is primary for standard declaration macros and supported user macros; Crystal interpreter is fallback for unsupported type-aware APIs |
| Facet-only validation | `CRA_FACET_ONLY=1` disables Crystal AST construction; all workspace LSP specs run against Facet alone in CI |

Each URI has a stable Facet `FileId`. A document version is parsed once and its
`AstFile`, `SyntaxTree`, diagnostics, parent map, and line index are reused by
all syntax consumers. Unchanged source bytes retain the cached query result.
Macro expansion invalidation is footprint-based, so edits to unrelated files
do not force re-expansion.

The server advertises incremental LSP text synchronization and applies UTF-16
range edits before advancing the Facet source revision. Frontend invalidation is
currently file-grained: an edited file is reparsed, but unchanged files and
unrelated macro expansions stay cached.

Project-owned macro consumers are materialized during the initial semantic
pass. Dependency and stdlib consumers remain lazy/legacy until needed; dirty
queues contain only expansions that were actually materialized, preventing an
editor startup from eagerly expanding the entire toolchain.

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
  with block content included in incremental expansion cache keys.
- Expanded Facet ASTs feed generated-only semantic slices, including completion,
  navigation, and call hierarchy in Crystal-rejected buffers. Macro-provider
  edits reindex only the footprint-invalidated consumer files.
- The complete workspace LSP contract runs with no Crystal AST: 97/97 examples
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
4. Extend Facet macro evaluation across type introspection, the remaining
   AST-node APIs, require-aware provider visibility, and full block/yield
   semantics; then remove the cr-analyzer interpreter and all
   `compiler/crystal/syntax` requires.

Run the local declaration gate after semantic changes:

```console
crystal run scripts/check_facet_semantic_parity.cr
```

Run the LSP cutover gate without constructing any Crystal AST:

```console
CRA_FACET_ONLY=1 crystal spec spec/cra/workspace
```

## Ownership

Facet owns source text, revisions, lexing, parsing, syntax diagnostics, native
AST queries, macro expansion, and expansion provenance. cr-analyzer owns LSP
transport, workspace policy, the editor semantic model, and protocol results.
