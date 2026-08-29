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
SERVER_ENTRYPOINT = PROJECT_ROOT / "src" / "bin" / "cra.cr"


def _server_env() -> dict[str, str]:
    return dict(os.environ)


@pytest_asyncio.fixture(scope="function")
async def lsp_client():
    print("[fixture] starting server")
    client = LanguageClient("cr-analyzer", "v0")
    await client.start_io(
        "crystal",
        "run",
        "-Dpreview_mt",
        "-Dexecution_context",
        str(SERVER_ENTRYPOINT),
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
        stop_event = getattr(client, "_stop_event", None)
        if stop_event:
            stop_event.set()

        if server:
            if server.stdin:
                server.stdin.close()
                try:
                    await server.stdin.wait_closed()
                except (BrokenPipeError, ConnectionResetError):
                    pass

            if server.returncode is None:
                server.terminate()
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

        async_tasks = getattr(client, "_async_tasks", [])
        for task in async_tasks:
            if not task.done():
                task.cancel()
        if async_tasks:
            await asyncio.gather(*async_tasks, return_exceptions=True)

        if stderr_task:
            if not stderr_task.done():
                stderr_task.cancel()
            await asyncio.gather(stderr_task, return_exceptions=True)

        # Ensure event loop sees completion
        await asyncio.sleep(0)
