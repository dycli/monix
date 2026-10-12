"""Hold one session open on the desktop's Playwright MCP server.

The server shares a single browser between its clients and closes it when
the last one leaves. The assistant connects once per reply, so without a
standing client the browser would vanish after every turn. This client
opens the browser at boot and stays connected; the session's own read loop
answers the server's pings.
"""

import asyncio
import os
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def main() -> None:
    url = os.environ["DESK_MCP"]
    async with streamablehttp_client(url) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            # The browser launches on the first tool call.
            await session.call_tool("browser_tabs", {"action": "list"})
            print("holding the browser open", flush=True)
            await asyncio.Event().wait()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:  # noqa: BLE001 - any failure restarts the unit
        print(f"keeper: {error}", file=sys.stderr)
        sys.exit(1)
