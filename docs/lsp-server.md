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
  document-symbol fallback, plus a declaration semantic shadow index and
  completion keyword/enclosing-syntax context. Receiver/member completion,
  navigation, rename, locals/calls, and inference remain on the temporary
  Crystal AST path during cutover.

## Manual testing

- Quick client harness: `uv run main.py` (uses `pyproject.toml` env).
- Logs are written to stderr.
