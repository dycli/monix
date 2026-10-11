"""Sokka's requests: a stdio MCP server over Seerr.

Usage: sokka-requests KEYFILE, Seerr's API key, raw, on the server
SOKKA_SEERR. Searches the catalogue, requests a film or a show's seasons
and lists what has been requested. A request is made under the Seerr
user whose name is SOKKA_PERSON when there is one, else under the key's
own account.
"""

import json
import os
import sys
from urllib.parse import quote
from urllib.request import Request, urlopen

from mcp.server.fastmcp import FastMCP

SEERR = os.environ["SOKKA_SEERR"]
PERSON = os.environ.get("SOKKA_PERSON", "")
TIMEOUT = 20
with open(sys.argv[1]) as f:
    KEY = f.read().strip()

MEDIA = {1: "unknown", 2: "pending", 3: "downloading", 4: "partly available", 5: "available"}
REQUEST = {1: "pending", 2: "approved", 3: "declined"}

server = FastMCP("requests")


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = Request(
        f"{SEERR}/api/v1{path}",
        data=data,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"},
    )
    with urlopen(request, timeout=TIMEOUT) as r:
        return json.load(r)


def year(stamp):
    return (stamp or "")[:4] or None


def status(info):
    return MEDIA.get((info or {}).get("status", 1), "unknown")


@server.tool()
def media_search(title: str) -> list[dict]:
    """Search films and shows; returns kind, tmdb id, title, year, overview and whether the library has it."""
    results = call(f"/search?query={quote(title)}&page=1")["results"]
    return [
        {
            "kind": r["mediaType"],
            "tmdb_id": r["id"],
            "title": r.get("title") or r.get("name"),
            "year": year(r.get("releaseDate") or r.get("firstAirDate")),
            "overview": (r.get("overview") or "")[:300],
            "library": status(r.get("mediaInfo")),
        }
        for r in results
        if r.get("mediaType") in ("movie", "tv")
    ][:10]


@server.tool()
def media_seasons(tmdb_id: int) -> dict:
    """A show's seasons, with how many episodes each has and which the library already holds."""
    show = call(f"/tv/{tmdb_id}")
    have = {s["seasonNumber"]: status(s) for s in (show.get("mediaInfo") or {}).get("seasons") or []}
    return {
        "title": show.get("name"),
        "seasons": [
            {
                "season": s["seasonNumber"],
                "episodes": s.get("episodeCount"),
                "library": have.get(s["seasonNumber"], "unknown"),
            }
            for s in show.get("seasons") or []
            if s["seasonNumber"] > 0
        ],
    }


def requester():
    """The Seerr user named like the person, if any."""
    if not PERSON:
        return None
    for u in call("/user?take=100")["results"]:
        names = (u.get("displayName"), u.get("jellyfinUsername"), u.get("plexUsername"))
        if any(n and n.lower() == PERSON.lower() for n in names):
            return u["id"]
    return None


@server.tool()
def media_request(kind: str, tmdb_id: int, seasons: list[int] | None = None) -> dict:
    """Request a film (kind movie) or a show (kind tv), the given seasons or, with none, all of them."""
    if kind not in ("movie", "tv"):
        raise ValueError("kind is movie or tv")
    body = {"mediaType": kind, "mediaId": tmdb_id}
    if kind == "tv":
        body["seasons"] = seasons or "all"
    user = requester()
    if user is not None:
        body["userId"] = user
    made = call("/request", body)
    return {
        "request": made["id"],
        "status": REQUEST.get(made.get("status"), "pending"),
        "requested_by": (made.get("requestedBy") or {}).get("displayName"),
    }


@server.tool()
def media_requests(count: int = 15) -> list[dict]:
    """The latest requests: what was asked for, by whom, and where it stands."""
    count = max(1, min(count, 50))
    results = call(f"/request?take={count}&sort=added&skip=0")["results"]
    return [
        {
            "request": r["id"],
            "kind": r["media"]["mediaType"],
            "tmdb_id": r["media"]["tmdbId"],
            "seasons": [s["seasonNumber"] for s in r.get("seasons") or []] or None,
            "requested_by": (r.get("requestedBy") or {}).get("displayName"),
            "status": REQUEST.get(r.get("status"), "pending"),
            "library": status(r.get("media")),
        }
        for r in results
    ]


if __name__ == "__main__":
    server.run()
