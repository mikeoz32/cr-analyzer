#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path
import select
import statistics
import subprocess
import time


def read_line(stream, deadline: float) -> bytes:
    remaining = deadline - time.monotonic()
    if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
        raise TimeoutError("timed out waiting for LSP initialize response")
    return stream.readline()


def read_exact(stream, size: int, deadline: float) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        timeout = deadline - time.monotonic()
        if timeout <= 0 or not select.select([stream], [], [], timeout)[0]:
            raise TimeoutError("timed out reading LSP initialize response body")
        chunk = stream.read(remaining)
        if not chunk:
            raise RuntimeError("server exited during initialize response body")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def initialize_once(binary: Path, root: Path, facet_only: bool, timeout: float) -> float:
    env = dict(os.environ)
    if facet_only:
        env["CRA_FACET_ONLY"] = "1"
    else:
        env.pop("CRA_FACET_ONLY", None)

    started = time.perf_counter()
    process = subprocess.Popen(
        [str(binary)],
        cwd=root,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    try:
        request = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "processId": None,
                    "rootUri": root.as_uri(),
                    "capabilities": {},
                },
            },
            separators=(",", ":"),
        ).encode()
        process.stdin.write(f"Content-Length: {len(request)}\r\n\r\n".encode() + request)

        deadline = time.monotonic() + timeout
        content_length = None
        while True:
            line = read_line(process.stdout, deadline)
            if not line:
                raise RuntimeError(f"server exited before initialize response: {process.poll()}")
            if line in {b"\r\n", b"\n"}:
                break
            name, value = line.decode().split(":", 1)
            if name.lower() == "content-length":
                content_length = int(value.strip())

        if content_length is None:
            raise RuntimeError("initialize response omitted Content-Length")
        body = read_exact(process.stdout, content_length, deadline)
        response = json.loads(body)
        if response.get("id") != 1 or "result" not in response:
            raise RuntimeError(f"unexpected initialize response: {response}")
        return time.perf_counter() - started
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def summarize(name: str, samples: list[float]) -> None:
    formatted = ",".join(f"{sample:.3f}" for sample in samples)
    print(
        f"{name}_seconds={formatted} "
        f"median={statistics.median(samples):.3f} "
        f"min={min(samples):.3f} max={max(samples):.3f}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare cr-analyzer initialize latency")
    parser.add_argument("--binary", type=Path, default=Path("bin/cr-analyzer"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()

    binary = args.binary.resolve()
    root = args.root.resolve()
    if not binary.is_file():
        raise SystemExit(f"binary not found: {binary}; run shards build --release")
    if args.repeat < 1:
        raise SystemExit("--repeat must be at least 1")
    if args.warmup < 0:
        raise SystemExit("--warmup must not be negative")

    for _ in range(args.warmup):
        initialize_once(binary, root, False, args.timeout)
        initialize_once(binary, root, True, args.timeout)

    legacy = []
    facet = []
    for index in range(args.repeat):
        modes = (False, True) if index % 2 == 0 else (True, False)
        for facet_only in modes:
            sample = initialize_once(binary, root, facet_only, args.timeout)
            (facet if facet_only else legacy).append(sample)

    print(f"root={root} repeat={args.repeat} warmup={args.warmup}")
    summarize("legacy", legacy)
    summarize("facet_only", facet)
    speedup = statistics.median(legacy) / statistics.median(facet)
    print(f"facet_only_speedup={speedup:.2f}x")


if __name__ == "__main__":
    main()
