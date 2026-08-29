# cr-analyzer

Lightweight LSP server for the Crystal language. cr-analyzer parses source files with the Crystal parser and builds a semantic index without invoking the full compiler, aiming for fast, editor-friendly feedback.

## What works today

- Workspace scan of project sources, `lib`, and Crystal stdlib.
- Navigation: declaration, definition, type definition, implementation.
- References for locals/ivars/cvars/types/enum members/methods (arity-aware).
- Hover with signatures and docs; signature help.
- Completion: members, types/aliases/enum members, variables, keywords, `require` paths, resolve for docs.
- Rename (best-effort across workspace), document highlights, selection ranges.
- Call hierarchy (incoming/outgoing), inline values.
- Document symbols + workspace symbols.
- Diagnostics (push + pull): syntax/parser errors and lint warnings (TODO/FIXME, empty rescue, trailing whitespace, duplicate requires, missing final newline, mixed indentation, unused args).

## Quick start

```bash
shards install
crystal run src/bin/cra.cr   # or shards build && ./bin/cr-analyzer
```

Point your editor's LSP client to that command (stdio).

### Stdlib lookup

Uses `CRYSTAL_PATH` or `CRYSTAL_HOME`; falls back to `/usr/share/crystal/src`.

## Docs

- [Architecture](architecture.md)
- [Facet Integration](facet-integration.md)
- [Semantic Index](semantic-index.md)
- [LSP Server](lsp-server.md)
- [Roadmap](roadmap.md)

## Local docs preview

```bash
pip install mkdocs mkdocs-material
mkdocs serve
```

## Roadmap snapshot

See the full [roadmap](roadmap.md) for the long list. Current opportunities include semantic tokens, folding ranges, inlay hints, code actions, and deeper Facet-backed parsing/indexing.
