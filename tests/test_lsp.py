import asyncio
from pathlib import Path

import pytest
from lsprotocol.types import (
    Position,
    CompletionParams,
    TextDocumentIdentifier,
    TextDocumentSyncKind,
    TextDocumentSyncOptions,
)
from pygls.lsp.client import LanguageClient


@pytest.mark.asyncio
async def test_advertises_incremental_text_sync(lsp_client: LanguageClient):
    sync = lsp_client.initialize_result.capabilities.text_document_sync
    assert isinstance(sync, TextDocumentSyncOptions)
    assert sync.change == TextDocumentSyncKind.Incremental


@pytest.mark.asyncio
async def test_completion_e2e(lsp_client: LanguageClient):
    root_uri = f"file://{Path(__file__).resolve().parents[1]}"
    doc_uri = f"{root_uri}/src/cra/types.cr"

    print("[test] requesting completions")
    result = await asyncio.wait_for(
        lsp_client.text_document_completion_async(
            params=CompletionParams(
                text_document=TextDocumentIdentifier(uri=doc_uri),
                position=Position(line=0, character=0),
            )
        ),
        timeout=15,
    )

    labels = [item.label for item in result.items]
    print(f"[test] got {len(labels)} completion items")
    assert labels, "Expected completion items"
