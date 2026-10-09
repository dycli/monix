"""Sokka's YouTube: a stdio MCP server over yt-dlp.

Searches YouTube and reads a video's captions as plain text, the
uploader's own if there are any, else YouTube's automatic ones. It
reaches YouTube only: links to any other site are refused, so nothing
read elsewhere can be carried out through it.
"""

import json
from urllib.parse import urlparse

from mcp.server.fastmcp import FastMCP
from yt_dlp import YoutubeDL

HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"}
TEXT = 200000

server = FastMCP("youtube")


def ydl(**opts):
    return YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True, **opts})


def minutes(seconds):
    if not seconds:
        return None
    m, s = divmod(int(seconds), 60)
    return f"{m // 60}:{m % 60:02}:{s:02}" if m >= 60 else f"{m}:{s:02}"


@server.tool()
def youtube_search(query: str, count: int = 10) -> list[dict]:
    """Search YouTube; returns title, channel, length, views and link per video."""
    count = max(1, min(count, 25))
    with ydl(extract_flat=True) as y:
        info = y.extract_info(f"ytsearch{count}:{query}", download=False)
    return [
        {
            "title": e.get("title"),
            "channel": e.get("channel") or e.get("uploader"),
            "length": minutes(e.get("duration")),
            "views": e.get("view_count"),
            "url": f"https://www.youtube.com/watch?v={e['id']}",
        }
        for e in info.get("entries") or []
        if e.get("id")
    ]


def pick(info, language):
    """The best caption track: own captions before automatic ones, the
    asked language before the video's original one."""
    own = info.get("subtitles") or {}
    auto = info.get("automatic_captions") or {}

    def match(tracks, want):
        for key in tracks:
            if key == want or key.startswith(want + "-"):
                return key
        return None

    for tracks, kind in ((own, "own"), (auto, "automatic")):
        key = match(tracks, language)
        if kind == "automatic":
            key = match(tracks, language + "-orig") or key
        if key:
            return tracks[key], kind, key
    for key in own:
        if key != "live_chat":
            return own[key], "own", key
    for key in auto:
        if key.endswith("-orig"):
            return auto[key], "automatic", key
    return None, None, None


@server.tool()
def youtube_transcript(url: str, language: str = "en") -> dict:
    """A YouTube video's title, channel, length and captions as plain text."""
    host = (urlparse(url).hostname or "").lower()
    if host not in HOSTS:
        raise ValueError("only youtube.com and youtu.be links")
    with ydl() as y:
        info = y.extract_info(url, download=False)
        formats, kind, key = pick(info, language)
        if not formats:
            raise ValueError("this video has no captions")
        track = next((f for f in formats if f.get("ext") == "json3"), None)
        if not track:
            raise ValueError("no readable caption format")
        events = json.loads(y.urlopen(track["url"]).read()).get("events") or []
    words = "".join(s.get("utf8", "") for e in events for s in e.get("segs") or [])
    text = " ".join(words.split())
    return {
        "title": info.get("title"),
        "channel": info.get("channel") or info.get("uploader"),
        "length": minutes(info.get("duration")),
        "captions": f"{kind} ({key})",
        "cut": len(text) > TEXT,
        "text": text[:TEXT],
    }


if __name__ == "__main__":
    server.run()
