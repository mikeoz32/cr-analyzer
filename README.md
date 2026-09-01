# cr-analyzer

cr-analyzer is a lightweight Language Server Protocol (LSP) server for the Crystal language. It uses Facet's incremental syntax frontend and builds an editor-oriented semantic index without invoking the full compiler.

## Status

Active development. Implemented LSP features include completion (with resolve), go-to-declaration/definition/type definition/implementation, hover, signature help, document symbols, document highlight, references, inline values, selection range, call hierarchy (incoming/outgoing), rename (best-effort), diagnostics (push + pull), workspace symbols, and full-text document sync (didOpen/didChange/didSave). Other LSP features are planned.

## Features

- Workspace scan of project sources, `lib`, and Crystal stdlib.
- Go to declaration/definition for:
  - types (class/module/enum)
  - methods and overloads (arity aware)
  - constructors (`new` -> `initialize`/`self.new`)
  - instance/class/local variables
  - aliases and enum members
- Go to type definition (best-effort type inference from annotations/assignments).
- Go to implementation for subclasses, includers, and method overrides.
- References (locals, ivars/cvars, types, enum members).
- Document symbols (outline) and workspace symbols.
- Hover with signature + documentation.
- Signature help with active parameter selection.
- Document highlight for locals/ivars/cvars and type paths.
- Selection ranges based on Facet syntax nesting.
- Inline values (variables in range).
- Call hierarchy (incoming/outgoing).
- Type hierarchy (prepare/super/sub types).
- Rename (prepare + apply; best-effort for locals, ivars, methods, type paths in workspace).
- Diagnostics:
  - Facet 0.1.5 parser diagnostics by default, with Crystal::Parser as a fallback.
  - Lint-style warnings (TODO/FIXME, empty rescue, trailing whitespace, duplicate `require`, missing final newline, mixed indentation, unused def/block args).
  - Both push and pull diagnostic flows supported.
- Completion:
  - member methods on `.` and `::`
  - instance/class/local variables
  - type/namespace and enum member completions (aliases included)
  - keyword completions based on context
  - `require` path suggestions
  - completion resolve for docs and signatures

## Limitations

- No full compiler type checking or complete type-aware macro expansion. Type inference is best-effort based on annotations and simple assignments.
- Facet incrementally expands standard declaration macros and a substantial
  user-macro subset, including lexical `@type`, indexed type resolution,
  method/instance-variable/constant and annotation metadata, and explicit
  ancestry. Its committed Crystal 1.21 runtime corpus matches exact output for
  517/900 portable contracts executed by the official evaluator specs,
  including all 371 self-contained contracts. Crystal-backed fallback remains
  for 117 program-context contracts, contextual compiler/type macro APIs, and
  semantic cases that need richer fixtures.
- Rename is best-effort and currently scoped to workspace files (stdlib is not edited).
- Facet owns the incremental document store, cached syntax/diagnostics, UTF-16
  mapping, cursor lookup, selection ranges, symbols, and the primary declaration
  semantic index. Completion, navigation, hover, signature help, references,
  rename, highlights, type hierarchy, and the incrementally invalidated call
  graph are Facet-first and work in many Crystal-rejected incomplete buffers.
  Supported macro-generated declarations also enter the Facet semantic index
  through incrementally invalidated `facet-macro:` slices. The temporary Crystal
  AST remains for unsupported macro semantics, inference fallback, and remaining
  cutover work. `CRA_FACET_ONLY=1` disables construction of that AST; the complete
  workspace LSP contract suite runs in this mode in CI.

## Usage

1. Install dependencies:

```
shards install
```

2. Run the server over stdio:

```
crystal run src/bin/cra.cr
```

Or build the binary:

```
shards build
./bin/cr-analyzer
```

3. Configure your editor to launch the command above as an LSP server.

### Documentation site

- Hosted docs (GitHub Pages): https://mikeoz32.github.io/cr-analyzer
- Local preview with MkDocs:
  ```
  pip install mkdocs mkdocs-material
  mkdocs serve
  ```

### stdlib scanning

The server uses CRYSTAL_PATH or CRYSTAL_HOME to locate the stdlib. If unset it falls back to /usr/share/crystal/src.

## Development

- Run specs: crystal spec
- Run the no-Crystal-AST workspace contract: `CRA_FACET_ONLY=1 crystal spec spec/cra/workspace`
- Compare built-server initialization modes: `python3 scripts/bench_lsp_initialize.py`
- Quick client harness: uv run main.py (uses the Python env in pyproject.toml)
- Debug: CRA_DUMP_ROOTS=1 to dump index roots after initial scan

## Docs

- docs/architecture.md
- docs/semantic-index.md
- docs/lsp-server.md
- docs/roadmap.md

## Contributing

Please open an issue or PR with a clear description and tests when possible.

## Contributors

- Mike Oz - creator and maintainer
