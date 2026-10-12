"""Hold the desktop's browser open while it is wanted.

The Playwright MCP server shares one browser between its clients and
closes it when the last one leaves; the assistant connects once per
reply. While a lease runs this keeper holds a session of its own, so
the browser and its pages live through a long task or a request to
leave it open, and close once the lease ends. Leases arrive over plain
HTTP on the guest's address: POST /hold?seconds=N (0 means until
released), POST /release, GET / for the state.
"""

import asyncio
import os
import sys
import time
from urllib.parse import parse_qs, urlsplit

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

FOREVER = float("inf")


class Keeper:
    def __init__(self, mcp: str) -> None:
        self.mcp = mcp
        # None: no lease; FOREVER: until released; else a monotonic time.
        self.until: float | None = None
        self.holder: asyncio.Task | None = None
        self.changed = asyncio.Event()

    def hold(self, seconds: int) -> None:
        self.until = FOREVER if seconds == 0 else time.monotonic() + seconds
        if self.holder is None or self.holder.done():
            self.holder = asyncio.create_task(self.keep())
        self.changed.set()

    def release(self) -> None:
        self.until = None
        self.changed.set()

    def state(self) -> str:
        if self.until is None:
            return "closed"
        if self.until == FOREVER:
            return "held until released"
        return f"held for {int(self.until - time.monotonic())}s"

    async def keep(self) -> None:
        while self.until is not None:
            try:
                await self.session()
            except Exception as error:  # noqa: BLE001 - open again
                print(f"keeper: {error}", file=sys.stderr, flush=True)
                await asyncio.sleep(3)
        print("let the browser go", flush=True)

    async def session(self) -> None:
        async with streamablehttp_client(self.mcp) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                # The browser launches on the first tool call.
                await session.call_tool("browser_tabs", {"action": "list"})
                print("holding the browser", flush=True)
                while self.until is not None:
                    wait = None
                    if self.until != FOREVER:
                        wait = self.until - time.monotonic()
                        if wait <= 0:
                            self.until = None
                            break
                    self.changed.clear()
                    try:
                        await asyncio.wait_for(self.changed.wait(), wait)
                    except TimeoutError:
                        pass


async def answer(keeper: Keeper, reader, writer) -> None:
    line = await reader.readline()
    while await reader.readline() not in (b"\r\n", b"\n", b""):
        pass
    parts = line.decode(errors="replace").split()
    method, target = (parts + ["", ""])[:2]
    url = urlsplit(target)
    status, body = 200, ""
    if method == "POST" and url.path == "/hold":
        seconds = parse_qs(url.query).get("seconds", ["1800"])[0]
        keeper.hold(int(seconds))
        body = keeper.state()
    elif method == "POST" and url.path == "/release":
        keeper.release()
        body = keeper.state()
    elif method == "GET" and url.path == "/":
        body = keeper.state()
    else:
        status, body = 404, "hold, release or /"
    reason = "OK" if status == 200 else "Not Found"
    writer.write(
        f"HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n{body}"
        .encode()
    )
    await writer.drain()
    writer.close()


async def main() -> None:
    keeper = Keeper(os.environ["DESK_MCP"])
    port = int(os.environ["DESK_KEEP_PORT"])
    server = await asyncio.start_server(
        lambda r, w: answer(keeper, r, w), "0.0.0.0", port
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
