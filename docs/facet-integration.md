# Facet Integration Plan

## Decision

Facet is ready for a deeper, incremental integration, but not for replacing the
Crystal AST semantic pipeline yet. The next step should make Facet a persistent
syntax service for open documents and compare its output with the existing path.

The production path should continue to use Crystal::Parser for semantic indexing
until declaration, span, and compatibility parity are measured on real projects.

## Current boundary

| Concern | Current implementation |
| --- | --- |
| Syntax diagnostics | Facet 0.1.5 |
| Error-tolerant AST | Produced by Facet, then discarded |
| Cursor node lookup | Crystal::ASTNode / Crystal::Visitor |
| Document/workspace symbols | Crystal::ASTNode / Crystal::Visitor |
| Semantic index and inference | Crystal::ASTNode / Crystal::Visitor |
| Macro support | Separate cr-analyzer interpreter; Facet expansion is not consumed |
| Incremental source queries | Facet QueryDb exists but is not connected to Workspace |

## Why not switch the semantic index now

- NodeFinder, document symbols, rename collectors, and both semantic indexing
  passes are implemented as Crystal::Visitor subclasses.
- Facet exposes a compact generic arena. Stable typed accessors or a visitor
  facade are needed before cr-analyzer should depend on child positions.
- Facet's ProgramIndex currently indexes macros, not types, methods, includes,
  calls, locals, or inheritance relationships.
- Lexer stdlib coverage and parser compatibility specs are strong foundations,
  but whole-project parser and declaration parity are not measured yet.
- The two projects have separate macro expansion models that need explicit
  ownership rather than silently running both for semantic output.

## Recommended next slice

1. Add stable Facet traversal/accessor APIs for declarations, names, bodies,
   parameters, type expressions, calls, and source spans.
2. Add a workspace-owned Facet document store mapping URI to `SourceManager`
   file IDs and backed by `QueryDb`.
3. Parse each open document once per text version and retain its `AstFile`.
   Produce diagnostics from that cached result instead of reparsing locally.
4. Build a Facet declaration collector in shadow mode. Compare classes, modules,
   enums, aliases, methods, and spans with `DocumentSymbolsIndex` in specs.
5. Use Facet document symbols as a fallback when Crystal::Parser rejects an
   incomplete edit. Keep the Crystal result authoritative for valid files first.
6. After corpus parity, extend the shadow index to includes, inheritance, calls,
   and variables before considering completion/navigation cutover.

## Required gates

- Parse the installed Crystal stdlib and representative shard/workspace corpora,
  recording every Facet-only diagnostic on code accepted by Crystal::Parser.
- Differential specs for declaration kinds, names, nesting, and source spans.
- Correct UTF-8 byte offset to LSP UTF-16 position conversion.
- didOpen/didChange/didSave invalidation specs, including dependent macro files.
- Startup, edit latency, and memory benchmarks for single-parse and dual-parse modes.
- A tested fallback switch so a Facet failure cannot disable semantic features.

## Suggested ownership

Facet should own lexing, parsing, syntax diagnostics, source versions, and macro
expansion provenance. cr-analyzer should own LSP transport, workspace policy, and
the editor semantic model. Keeping that boundary explicit allows Facet to grow
toward a compiler without coupling its internal arena directly to LSP protocol
types.
