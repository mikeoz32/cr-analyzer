# LSP Server

## Transport

The server runs over stdio (stdin/stdout) and uses JSON-RPC.

## Implemented requests / notifications

- initialize / shutdown / exit
- textDocument/didOpen, didChange (full text), didSave, didClose
- textDocument/completion (+ completionItem/resolve)
- textDocument/hover
- textDocument/signatureHelp
- textDocument/definition, declaration, typeDefinition, implementation
- textDocument/references
- textDocument/documentHighlight
- textDocument/selectionRange
- textDocument/inlineValue (push + pull)
- textDocument/prepareRename, rename
- textDocument/documentSymbol
- workspace/symbol
- textDocument/diagnostic (pull) + publishDiagnostics (push)
- callHierarchy/prepare, incomingCalls, outgoingCalls
- typeHierarchy/prepare, supertypes, subtypes

## Capabilities status

ServerCapabilities are kept in sync with implemented handlers. Notable gaps: semantic tokens, code actions/lens, formatting, document links, code actions/formatting, inlay hints, moniker.

## Completion providers

- `CRA::Psi::SemanticIndex` (types, methods, vars, enum members, aliases, require paths for stdlib/lib/workspace)
- `CRA::KeywordCompletionProvider`
- `CRA::RequirePathCompletionProvider`

## Diagnostics

- Default: Facet 0.1.5 parser diagnostics plus lint-style warnings (TODO/FIXME, empty rescue, trailing whitespace, duplicate require, missing final newline, mixed indentation, unused args/block args).
- Fallback: Crystal::Parser when Facet diagnostics fail internally or when `CRA_DISABLE_FACET_DIAGNOSTICS=1`.
- Scope: Facet now provides cached syntax, cursor lookup, selection ranges, and
  document/workspace symbols, plus the primary declaration semantic index.
  Completion, navigation, hover, signature help, references, rename, highlights,
  inline values, type hierarchy, and call hierarchy use Facet first, including
  tested Crystal-rejected buffers. Call sites are cached per file and semantic
  edges are resolved lazily per workspace revision.
  Supported macro-generated declarations use Facet's cached expansion and
  generated-only semantic slices. Unsupported type-aware macro APIs, inference,
  and remaining fallbacks still use the temporary Crystal AST path during
  cutover.

## Manual testing

- Quick client harness: `uv run main.py` (uses `pyproject.toml` env).
- Logs are written to stderr.
