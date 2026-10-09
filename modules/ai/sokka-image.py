"""Sokka's pictures: a stdio MCP server in front of the image service.

The service (`sokka-image`) holds the household's one Codex login and
answers a description with a PNG; this server never sees that login. It
leaves each picture in the instance's outbox, and the assistant sends
what waits there with its answer, then deletes it.
"""

import os
import socket
import sys
import time

from mcp.server.fastmcp import FastMCP

SOCKET = "/run/sokka-image.sock"
LIMIT = 30 * 1024 * 1024
OUTBOX = sys.argv[1]

server = FastMCP("image")


@server.tool()
def make_image(description: str) -> str:
    """Draw a picture from a description and send it with your answer.
    Describe subject, style and composition in a few sentences; takes about
    a minute."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(360)
        s.connect(SOCKET)
        s.sendall(description[:4000].encode())
        s.shutdown(socket.SHUT_WR)
        data = b""
        while len(data) <= LIMIT:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            data += chunk
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) > LIMIT:
        return "The picture failed; say so."
    os.makedirs(OUTBOX, exist_ok=True)
    name = os.path.join(OUTBOX, f"{time.time_ns()}.png")
    with open(name + ".part", "wb") as f:
        f.write(data)
    os.rename(name + ".part", name)
    return "Done; it goes out with your answer."


if __name__ == "__main__":
    server.run()
