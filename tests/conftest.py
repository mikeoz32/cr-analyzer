import asyncio
import os
from pathlib import Path

import pytest_asyncio
from lsprotocol.types import (
    ClientCapabilities,
    InitializeParams,
    CompletionClientCapabilities,
    TextDocumentClientCapabilities,
)
from pygls.lsp.client import LanguageClient

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CRYSTAL_SRC = PROJECT_ROOT / "src" / "cr-analyzer.cr"


def _server_env() -> dict[str, str]:
    return {
        **os.environ,
        "CRA_RUN_SERVER": "1",
    }


@pytest_asyncio.fixture(scope="function")
async def lsp_client():
    print("[fixture] starting server")
    client = LanguageClient("cr-analyzer", "v0")
    await client.start_io(
        "crystal",
        "run",
        "-Dpreview_mt",
        "-Dexecution_context",
        str(CRYSTAL_SRC),
        env=_server_env(),
        cwd=str(PROJECT_ROOT),
    )
    server = getattr(client, "_server", None)

    stderr_task = None
    if server and server.stderr:

        async def _pump_stderr():
            while True:
                line = await server.stderr.readline()
                if not line:
                    break
                print("[server stderr]", line.decode().rstrip())

        stderr_task = asyncio.create_task(_pump_stderr())
    print("[fixture] server process started")

    try:
        await client.initialize_async(
            params=InitializeParams(
                capabilities=ClientCapabilities(
                    text_document=TextDocumentClientCapabilities(
                        completion=CompletionClientCapabilities()
                    )
                ),
                root_uri=f"file://{PROJECT_ROOT}",
            )
        )
        print("[fixture] initialize completed")
    except RuntimeError:
        server = getattr(client, "_server", None)
        if server and server.stderr:
            err = await server.stderr.read()
            print("[fixture] init stderr:\n", err.decode())
            raise RuntimeError(err.decode() or "server exited during initialize")
        raise

    try:
        yield client
    finally:
        print("[fixture] tearing down")
        # Avoid shutdown/exit to prevent hangs; just stop the client and wait for process
        await client.stop()
        if server:
            try:
                await asyncio.wait_for(server.wait(), timeout=5)
            except asyncio.TimeoutError:
                print("[fixture] server wait timed out; killing")
                server.kill()
                await server.wait()

            if server.returncode and server.stderr:
                err = await server.stderr.read()
                if err:
                    print("[fixture] server stderr during teardown:\n", err.decode())
        if stderr_task:
            await stderr_task
        # Ensure event loop sees completion
        await asyncio.sleep(0)
