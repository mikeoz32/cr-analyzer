import asyncio

from lsprotocol import types
from pygls.lsp.client import LanguageClient


async def main():
    print("Hello from cr-analyzer!")
    client = LanguageClient("cr-analyzer", "v1")
    await client.start_io(
        "crystal", "run", "-Dpreview_mt", "-Dexecution_context", "src/bin/cra.cr"
    )
    response = await client.initialize_async(
        params=types.InitializeParams(
            capabilities=types.ClientCapabilities(
                workspace=types.WorkspaceClientCapabilities(apply_edit=True)
            ),
            root_uri="file:///home/mike/cr-analyzer",
        )
    )
    print(response)
    response = await client.text_document_completion_async(
        params=types.CompletionParams(
            text_document=types.TextDocumentIdentifier(
                uri="file:///home/mike/cr-analyzer/src/cra/types.cr"
            ),
            position=types.Position(line=0, character=0),
        )
    )

    print(f"Got {len(response.items)} completion items")


if __name__ == "__main__":
    asyncio.run(main())
