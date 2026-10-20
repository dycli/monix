"""Sokka's pictures: a stdio MCP server in front of two artists.

ChatGPT is the image service (`yeoman-image`), which holds the
household's one Codex login and answers a description with a PNG. Grok
is the X service (`yeoman x`), which holds the xAI sign-in and answers
with a JPEG from Grok Imagine. This server sees neither login. It leaves
each picture in the instance's outbox, and the assistant sends what
waits there with its answer, then deletes it.
"""

import base64
import json
import os
import socket
import sys
import time

from mcp.server.fastmcp import FastMCP

CHATGPT = "/run/yeoman-image.sock"
GROK = "/run/yeoman-x.sock"
LIMIT = 30 * 1024 * 1024
OUTBOX = sys.argv[1]

server = FastMCP("image")


def ask(path: str, body: bytes) -> bytes:
    """One request over a service's socket; its whole reply, or b"" when
    it runs past the limit."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(360)
        s.connect(path)
        s.sendall(body)
        s.shutdown(socket.SHUT_WR)
        data = b""
        while len(data) <= LIMIT:
            chunk = s.recv(1 << 16)
            if not chunk:
                return data
            data += chunk
    return b""


def chatgpt(description: str) -> tuple[bytes, str]:
    data = ask(CHATGPT, description.encode())
    return data, "png" if data.startswith(b"\x89PNG\r\n\x1a\n") else ""


def grok(description: str) -> tuple[bytes, str]:
    reply = ask(GROK, json.dumps({"draw": description}).encode())
    try:
        data = base64.b64decode(json.loads(reply)["image"])
    except (ValueError, KeyError, TypeError):
        return b"", ""
    return data, "jpg" if data.startswith(b"\xff\xd8\xff") else ""


ARTISTS = {"chatgpt": chatgpt, "grok": grok}


@server.tool()
def make_image(description: str, artist: str = "chatgpt") -> str:
    """Draw a picture from a description and send it with your answer.
    Describe subject, style and composition in a few sentences. The artist
    is "chatgpt" (the default; about a minute, best with words in the
    picture and exact layouts) or "grok" (Grok Imagine, a few seconds);
    use the one the person asks for."""
    draw = ARTISTS.get(artist.strip().lower())
    if draw is None:
        return 'No such artist; use "chatgpt" or "grok".'
    try:
        data, kind = draw(description[:4000])
    except OSError:
        data, kind = b"", ""
    if not kind:
        return "The picture failed; say so."
    os.makedirs(OUTBOX, exist_ok=True)
    name = os.path.join(OUTBOX, f"{time.time_ns()}.{kind}")
    with open(name + ".part", "wb") as f:
        f.write(data)
    os.rename(name + ".part", name)
    return "Done; it goes out with your answer."


if __name__ == "__main__":
    server.run()
