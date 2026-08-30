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
| Document symbols | Facet shadow collector; Facet fallback for incomplete buffers |
| Declaration semantic index | Facet shadow index for types, methods, aliases, includes, inheritance, enum members, docs, and locations |
| Workspace symbols | Crystal document-symbol index while public-result parity is measured |
| Completion prefixes, enclosing syntax, keywords | Facet `LineIndex` + `FacetNodeFinder` + named condition roles |
| Receiver/member and named-argument completion | Facet-first named receiver/call/parameter roles; Crystal fallback for unsupported inference shapes |
| Locals and scoped variables | Facet local-name collection and typed/constructor assignment inference, including incomplete buffers |
| Navigation, references, rename, and call graph | Crystal AST consumers being migrated |
| Macro support | Separate cr-analyzer interpreter; Facet expansion is not consumed yet |

Each URI has a stable Facet `FileId`. A document version is parsed once and its
`AstFile`, `SyntaxTree`, diagnostics, parent map, and line index are reused by
all syntax consumers. Unchanged source bytes retain the cached query result.
Macro expansion invalidation is footprint-based, so edits to unrelated files
do not force re-expansion.

The server advertises incremental LSP text synchronization and applies UTF-16
range edits before advancing the Facet source revision. Frontend invalidation is
currently file-grained: an edited file is reparsed, but unchanged files and
unrelated macro expansions stay cached.

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
  cr-analyzer source/spec corpus is exact on 62/62 Crystal-accepted files, with
  one additional Facet recovery from a Crystal-rejected file.
- Tested document-symbol and selection-range behavior on incomplete buffers
  rejected by Crystal::Parser.
- Facet-backed completion prefixes, enclosing type context, and keyword-context
  classification, including incomplete conditions and astral UTF-16 positions.
- Facet-first receiver/member and named-argument completion, including typed and
  constructor-assigned locals, chained generic returns, local names, and
  instance/class variables in buffers rejected by Crystal::Parser.

## Remaining cutover work

1. Extend Facet inference to block-yield parameter types and remaining literal,
   call, and control-flow shapes, then retire the completion fallback.
2. Reuse Facet roles for navigation, references, rename, and call graphs.
3. Compare shadow semantic and public LSP results on stdlib and representative
   workspaces, not only focused declaration contracts.
4. Make Facet authoritative feature by feature, retaining an explicit rollback
   switch until each differential gate is clean.
5. Feed Facet's fully expanded AST into semantic indexing, then remove the
   cr-analyzer macro interpreter and all `compiler/crystal/syntax` requires.

Run the local declaration gate after semantic changes:

```console
crystal run scripts/check_facet_semantic_parity.cr
```

## Ownership

Facet owns source text, revisions, lexing, parsing, syntax diagnostics, native
AST queries, macro expansion, and expansion provenance. cr-analyzer owns LSP
transport, workspace policy, the editor semantic model, and protocol results.
