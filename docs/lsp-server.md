# LSP Server

## Transport

The server runs over stdio (stdin/stdout) and uses JSON-RPC.

## Implemented requests

- initialize
- textDocument/didOpen
- textDocument/didChange (full text)
- textDocument/didSave (full text)
- textDocument/completion
- completionItem/resolve
- textDocument/definition
- textDocument/hover

Document symbols are implemented in DocumentSymbolsIndex and advertised in capabilities.

## Capabilities status

ServerCapabilities currently advertises references, rename, typeDefinition, implementation, and workspaceSymbol, but handlers are not implemented yet. Keep this list in sync when adding support.

## Completion providers

- CRA::Psi::SemanticIndex
- CRA::KeywordCompletionProvider
- CRA::RequirePathCompletionProvider

## Manual testing

- uv run main.py (requires the Python env in pyproject.toml)
- Logs are written to stderr.
