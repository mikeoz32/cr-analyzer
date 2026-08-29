# cr-analyzer

cr-analyzer is a lightweight Language Server Protocol (LSP) server for the Crystal language. It parses source files with the Crystal parser and builds a semantic index without invoking the full compiler, aiming for fast, editor-friendly feedback.

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
- Selection ranges based on AST nesting.
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

- No full compiler type checking or macro expansion. Type inference is best-effort based on annotations and simple assignments.
- Macro expansion is limited to built-in macros (getter, setter, property, record) and a small interpreter for user-defined macros.
- Rename is best-effort and currently scoped to workspace files (stdlib is not edited).
- Facet currently supplies diagnostics only. Semantic indexing and editor navigation still consume `Crystal::ASTNode` from Crystal::Parser.

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
