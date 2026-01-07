import asyncio
import tempfile
from pathlib import Path

from lsprotocol import types
from pygls.lsp.client import LanguageClient

SAMPLE_CODE = """\
class Greeter
  def greet
  end

  def grab
  end
end

class Box
  def initialize
    @bar = 1
    @baz = 2
  end

  def value
    @ba
  end
end

def call
  greeter = Greeter.new
  greeter.gr
end

def keyword_demo
  ret
end

require \"foo/ba\"
"""

REQUEST_TIMEOUT = 10.0
INIT_TIMEOUT = 60.0


def log(message: str) -> None:
    print(message, flush=True)


def position_for(text: str, needle: str, offset: int = 0, occurrence: int = 0) -> types.Position:
    idx = -1
    for _ in range(occurrence + 1):
        idx = text.index(needle, idx + 1)
    idx += offset
    line = text.count("\n", 0, idx)
    last_nl = text.rfind("\n", 0, idx)
    col = idx - (last_nl + 1 if last_nl != -1 else 0)
    return types.Position(line=line, character=col)


async def stop_client(client: LanguageClient) -> None:
    stop_event = getattr(client, "_stop_event", None)
    if stop_event:
        stop_event.set()

    server_proc = getattr(client, "_server", None)
    if server_proc:
        stdin = getattr(server_proc, "stdin", None)
        if stdin:
            stdin.close()
            try:
                await stdin.wait_closed()
            except Exception:
                pass

        if server_proc.returncode is None:
            server_proc.terminate()
            try:
                await asyncio.wait_for(server_proc.wait(), timeout=2.0)
            except asyncio.TimeoutError:
                server_proc.kill()
                await server_proc.wait()

    async_tasks = getattr(client, "_async_tasks", [])
    for task in async_tasks:
        if not task.done():
            task.cancel()
    if async_tasks:
        await asyncio.gather(*async_tasks, return_exceptions=True)


async def await_with_timeout(coro, label: str, timeout: float) -> types.CompletionList | types.InitializeResult:
    try:
        return await asyncio.wait_for(coro, timeout=timeout)
    except asyncio.TimeoutError:
        log(f"[timeout] {label} after {timeout}s")
        raise


async def request_completion(
    client: LanguageClient,
    uri: str,
    position: types.Position,
    trigger_character: str | None = None,
) -> types.CompletionList:
    if trigger_character:
        context = types.CompletionContext(
            trigger_kind=types.CompletionTriggerKind.TriggerCharacter,
            trigger_character=trigger_character,
        )
    else:
        context = types.CompletionContext(
            trigger_kind=types.CompletionTriggerKind.Invoked,
        )

    params = types.CompletionParams(
        text_document=types.TextDocumentIdentifier(uri=uri),
        position=position,
        context=context,
    )
    return await client.text_document_completion_async(params=params)


def print_result(title: str, items: list[types.CompletionItem], expected: list[str]) -> None:
    labels = {item.label for item in items}
    hits = [label for label in expected if label in labels]
    misses = [label for label in expected if label not in labels]
    log(f"{title}: {len(items)} items")
    if hits:
        log("  hits: " + ", ".join(hits))
    if misses:
        log("  missing: " + ", ".join(misses))


async def main() -> None:
    client = LanguageClient("cr-analyzer", "v1")
    log("starting server...")
    await client.start_io(
        "crystal",
        "run",
        "-Dpreview_mt",
        "-Dexecution_context",
        "src/bin/cra.cr",
    )
    log("server started")

    async def _drain_stderr(server_proc: asyncio.subprocess.Process | None) -> None:
        if server_proc is None or server_proc.stderr is None:
            return
        async for line in server_proc.stderr:
            text = line.decode(errors="replace").rstrip()
            if "ERROR" in text or "Error" in text or "error" in text:
                log(f"[server stderr] {text}")

    stderr_task = asyncio.create_task(_drain_stderr(client._server))

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "src" / "foo").mkdir(parents=True, exist_ok=True)
            (root / "src" / "foo" / "bar.cr").write_text("")
            (root / "src" / "foo" / "baz.cr").write_text("")
            sample_path = root / "sample.cr"
            sample_path.write_text(SAMPLE_CODE)

            log("initializing...")
            await await_with_timeout(
                client.initialize_async(
                    params=types.InitializeParams(
                        capabilities=types.ClientCapabilities(
                            workspace=types.WorkspaceClientCapabilities(apply_edit=True)
                        ),
                        root_uri=root.as_uri(),
                    )
                ),
                "initialize",
                INIT_TIMEOUT,
            )
            client.initialized(types.InitializedParams())
            log("initialized")

            client.text_document_did_open(
                types.DidOpenTextDocumentParams(
                    text_document=types.TextDocumentItem(
                        uri=sample_path.as_uri(),
                        language_id="crystal",
                        version=1,
                        text=SAMPLE_CODE,
                    )
                )
            )
            log("didOpen sent")

            await asyncio.sleep(0.2)

            method_pos = position_for(SAMPLE_CODE, "greeter.gr", offset=len("greeter.gr"))
            method_items = (
                await await_with_timeout(
                    request_completion(client, sample_path.as_uri(), method_pos, "."),
                    "completion(method)",
                    REQUEST_TIMEOUT,
                )
            ).items
            print_result("method completion", method_items, ["greet", "grab"])

            ivar_pos = position_for(SAMPLE_CODE, "@ba", offset=len("@ba"))
            ivar_items = (
                await await_with_timeout(
                    request_completion(client, sample_path.as_uri(), ivar_pos, "@"),
                    "completion(ivar)",
                    REQUEST_TIMEOUT,
                )
            ).items
            print_result("ivar completion", ivar_items, ["@bar", "@baz"])

            keyword_pos = position_for(SAMPLE_CODE, "ret", offset=len("ret"))
            keyword_items = (
                await await_with_timeout(
                    request_completion(client, sample_path.as_uri(), keyword_pos),
                    "completion(keyword)",
                    REQUEST_TIMEOUT,
                )
            ).items
            print_result("keyword completion", keyword_items, ["return"])

            require_pos = position_for(SAMPLE_CODE, "foo/ba", offset=len("foo/ba"))
            require_items = (
                await await_with_timeout(
                    request_completion(client, sample_path.as_uri(), require_pos),
                    "completion(require)",
                    REQUEST_TIMEOUT,
                )
            ).items
            print_result("require completion", require_items, ["foo/bar", "foo/baz"])
    finally:
        stderr_task.cancel()
        try:
            await stderr_task
        except asyncio.CancelledError:
            pass
        await stop_client(client)


if __name__ == "__main__":
    asyncio.run(main())
