"""Who used the subscriptions: given window starts on stdin as JSON
({"claude": {"5h": epoch, ...}, "codex": {...}}), answers with the API-price
dollars each assistant used in each window since its start. The seat's own
use comes from its transcripts (Claude Code, Codex, OpenCode); the
household's, and every memory's, from one journal line per call. Prices
weight the tokens so that a share means a share of what the limit meters;
the dollars are what the same tokens would cost on the API. Reads only."""

import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HOME = Path(os.environ["SEAT_HOME"])
SEAT = os.environ["SEAT_NAME"]

# $ per million tokens: input, cached input, output. Claude cache writes
# cost 1.25x input for five minutes, 2x for an hour.
PRICES = [
    ("claude-opus-5", 4, 0.4, 20),
    ("claude-sonnet-5", 2, 0.2, 10),
    ("claude-haiku-5", 0.10, 0.01, 0.50),
    ("claude-haiku-4", 1, 0.1, 5),
    ("claude-fable-5", 10, 1, 50),
    ("gpt-6-astra", 10, 1, 50),
    ("luna", 0.10, 0.01, 0.50),
    ("gpt-", 2, 0.2, 10),
]


def cost(model, input, cached, write5m, write1h, output):
    for prefix, i, c, o in PRICES:
        if prefix in model:
            return (input * i + cached * c + write5m * i * 1.25 + write1h * i * 2 + output * o) / 1e6
    return 0.0


def epoch(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


def provider(model):
    return "codex" if model.startswith("gpt-") else "claude"


def claude_code(since):
    """The seat's Claude Code transcripts, subagents included, each request
    counted once (ccusage's rule)."""
    seen = set()
    for f in (HOME / ".claude/projects").rglob("*.jsonl"):
        if f.stat().st_mtime < since:
            continue
        with open(f, errors="replace") as fh:
            for raw in fh:
                if '"usage"' not in raw:
                    continue
                try:
                    ev = json.loads(raw)
                except ValueError:
                    continue
                msg = ev.get("message") or {}
                u, model = msg.get("usage"), msg.get("model", "")
                if ev.get("type") != "assistant" or not u or model.startswith("<"):
                    continue
                key = (msg.get("id"), ev.get("requestId"))
                if key in seen:
                    continue
                seen.add(key)
                split = u.get("cache_creation") or {}
                h1 = split.get("ephemeral_1h_input_tokens", 0)
                m5 = u.get("cache_creation_input_tokens", 0) - h1
                yield "claude", (SEAT, ""), epoch(ev["timestamp"]), cost(
                    model, u.get("input_tokens", 0), u.get("cache_read_input_tokens", 0), m5, h1, u.get("output_tokens", 0))


def codex(since):
    """The seat's Codex sessions; a token count repeated unchanged is one."""
    for f in (HOME / ".codex/sessions").rglob("rollout-*.jsonl"):
        if f.stat().st_mtime < since:
            continue
        model, total = "", None
        with open(f, errors="replace") as fh:
            for raw in fh:
                if '"turn_context"' not in raw and '"token_count"' not in raw:
                    continue
                ev = json.loads(raw)
                p = ev.get("payload") or {}
                if ev.get("type") == "turn_context":
                    model = p.get("model", model)
                elif p.get("type") == "token_count" and p.get("info"):
                    if p["info"]["total_token_usage"] == total:
                        continue
                    total = p["info"]["total_token_usage"]
                    u = p["info"]["last_token_usage"]
                    cached = u.get("cached_input_tokens", 0)
                    yield "codex", (SEAT, ""), epoch(ev["timestamp"]), cost(
                        model, u["input_tokens"] - cached, cached, 0, 0, u["output_tokens"])


def opencode(since):
    """The seat's OpenCode chats on the ChatGPT login (Go has one user)."""
    db = HOME / ".local/share/opencode/opencode-stable.db"
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(
        "select data from message where json_extract(data, '$.role') = 'assistant'"
        " and json_extract(data, '$.providerID') = 'openai'"
        " and json_extract(data, '$.time.created') >= ?", (since * 1000,))
    for (data,) in rows:
        m = json.loads(data)
        t = m.get("tokens") or {}
        c = t.get("cache") or {}
        yield "codex", (SEAT, ""), m["time"]["created"] / 1000, cost(
            m["modelID"], t.get("input", 0), c.get("read", 0), 0, 0, t.get("output", 0) + t.get("reasoning", 0))


LINE = re.compile(r"tokens model=(\S+) input=(\d+) cache_read=(\d+) cache_write=(\d+) output=(\d+)")


def who(unit):
    """`hippo` is the seat's memory, `<name>-hippo` an assistant's,
    `sokka-image@` the household's pictures, any other unit an assistant."""
    stem = unit.removesuffix(".service").split("@")[0]
    if stem == "hippo":
        return SEAT, "memory"
    if stem.endswith("-hippo"):
        return stem.removesuffix("-hippo"), "memory"
    if stem == "sokka-image":
        return "pictures", ""
    return stem, ""


def journal(since):
    """One line per call from the assistants, the memories and pictures.
    Memories cache for five minutes, the assistants for an hour."""
    out = subprocess.run(
        ["journalctl", "--since", f"@{int(since)}", "--grep", "tokens model=", "-o", "json", "--no-pager"],
        capture_output=True, text=True, check=False).stdout
    for raw in out.splitlines():
        ev = json.loads(raw)
        m = LINE.search(ev.get("MESSAGE") or "")
        if not m:
            continue
        model = m[1]
        i, r, w, o = map(int, m.groups()[1:])
        agent = who(ev.get("_SYSTEMD_UNIT", ""))
        five = agent[1] == "memory"
        yield provider(model), agent, int(ev["__REALTIME_TIMESTAMP"]) / 1e6, cost(
            model, i, r, w if five else 0, 0 if five else w, o)


windows = json.loads(sys.stdin.readline())
since = min(s for ws in windows.values() for s in ws.values())
spent = {p: {w: {} for w in ws} for p, ws in windows.items()}
for source in (claude_code, codex, opencode, journal):
    try:
        for prov, agent, at, dollars in source(since):
            for w, start in windows.get(prov, {}).items():
                if at >= start:
                    key = " ".join(filter(None, agent))
                    spent[prov][w][key] = spent[prov][w].get(key, 0) + dollars
    except Exception as e:
        print(f"usage-share: {source.__name__}: {type(e).__name__}: {e}", file=sys.stderr)
print(json.dumps(spent))
