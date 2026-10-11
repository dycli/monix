"""Sokka's web: a stdio MCP server in front of Parallel's keyless search.

Search passes through. Fetch opens only links that a search in this same
call returned, or that the person wrote themselves: a link the model
made up could carry what it has read (mail, memory) out in its path or
query, but a link that existed before it read anything carries nothing.
Pages can still say anything; what they say is information, not
instruction.
"""

import json
import os
import re
import socket
from urllib.parse import urlsplit

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from mcp.server.fastmcp import FastMCP

PARALLEL = "https://search.parallel.ai/mcp"
HIPPO = os.path.join(os.environ["HIPPO_DIR"], "hippo.sock")

server = FastMCP("web")
seen = set()


def key(url):
    """A link as compared: scheme and host lowercased, no fragment or trailing slash."""
    u = urlsplit(url.strip())
    return f"{u.scheme.lower()}://{u.netloc.lower()}{u.path.rstrip('/')}" + (f"?{u.query}" if u.query else "")


def written(url):
    """Whether the person wrote this link in a message of theirs."""
    pattern = re.sub(r"([\\.+*?()|\[\]{}^$#&\-~])", r"\\\1", url.strip())
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(HIPPO)
        s.sendall((json.dumps({"cmd": "search", "args": [pattern]}) + "\n").encode())
        reply = json.loads(s.makefile().readline())
    if not reply.get("ok"):
        return False
    return any(line.split(" ", 2)[1:2] == ["user"] for line in reply["out"].splitlines() if line[:1].isdigit())


async def parallel(tool, args):
    async with streamablehttp_client(PARALLEL) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            res = await s.call_tool(tool, args)
    return "\n".join(c.text for c in res.content if hasattr(c, "text"))


@server.tool()
async def web_search(objective: str, search_queries: list[str]) -> str:
    """Search the web. objective: what you are trying to find, in a sentence.
    search_queries: 1-3 keyword queries of 3-6 words. Results carry excerpts
    that usually answer directly."""
    text = await parallel("web_search", {"objective": objective, "search_queries": search_queries})
    try:
        for r in json.loads(text).get("results", []):
            if r.get("url"):
                seen.add(key(r["url"]))
    except ValueError:
        pass
    return text


@server.tool()
async def web_fetch(urls: list[str], objective: str | None = None) -> str:
    """Read whole pages, when search excerpts are not enough. Only links a
    web_search in this conversation returned, or that the person sent, can
    be opened. objective: what you want from the pages."""
    refused = [u for u in urls if key(u) not in seen and not written(u)]
    if refused:
        return "Refused, not from a search here or from the person: " + ", ".join(refused)
    args = {"urls": urls}
    if objective:
        args["objective"] = objective
    return await parallel("web_fetch", args)


if __name__ == "__main__":
    server.run()
