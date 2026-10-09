"""One connection, one report: how much of each subscription's limits is
used, read live from each provider, and under each Claude and Codex window
who used it, from usage-share. Claude and OpenCode Go logins arrive as
systemd credentials; Codex runs its own app-server on the household login,
which keeps that login fresh itself. Nothing is stored."""

import json
import os
import socket
import subprocess
import threading
import time
import urllib.request
from datetime import datetime

CREDS = os.environ["CREDENTIALS_DIRECTORY"]


def get(url, token, headers=None):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "User-Agent": "usage/1", **(headers or {})})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def when(at):
    if isinstance(at, (int, float)):
        t = datetime.fromtimestamp(at)
    else:
        t = datetime.fromisoformat(at.replace("Z", "+00:00")).astimezone()
    return t.strftime("%a %b %-d %H:%M")


def stamp(at):
    if isinstance(at, (int, float)):
        return at
    return datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()


def line(account, window, pct, at, length=None):
    """A window's line; with its length, also its start for usage-share."""
    text = f"{account:<7} {window:<5} {pct:3.0f}%  resets {when(at)}"
    return (text, account, window, stamp(at) - length) if length else text


def claude():
    with open(f"{CREDS}/claude") as f:
        login = json.load(f)["claudeAiOauth"]
    if login["expiresAt"] / 1000 < time.time():
        return ["claude  unknown (the seat's login lapsed; it renews when the seat next runs claude)"]
    out = get("https://api.anthropic.com/api/oauth/usage", login["accessToken"], {"anthropic-beta": "oauth-2025-04-20"})
    names = {"five_hour": ("5h", 5 * 3600), "seven_day": ("week", 7 * 86400)}
    return [line("claude", n, out[k]["utilization"], out[k]["resets_at"], length) for k, (n, length) in names.items() if out.get(k)]


def codex():
    p = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    timer = threading.Timer(30, p.kill)
    timer.start()
    try:
        def send(msg):
            p.stdin.write(json.dumps({"jsonrpc": "2.0", **msg}) + "\n")
            p.stdin.flush()

        def reply(id):
            for raw in p.stdout:
                msg = json.loads(raw)
                if msg.get("id") == id:
                    return msg["result"]
            raise RuntimeError("codex app-server closed")

        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "usage", "version": "1"}}})
        reply(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "account/rateLimits/read"})
        out = reply(2)
    finally:
        timer.cancel()
        p.kill()
    limits = out["rateLimits"]
    lines = []
    for w in (limits.get("primary"), limits.get("secondary")):
        if w:
            mins = w["windowDurationMins"]
            name = {300: "5h", 10080: "week"}.get(mins, f"{mins}m")
            lines.append(line("codex", name, w["usedPercent"], w["resetsAt"], mins * 60))
    resets = sum(c["status"] == "available" for c in (out.get("rateLimitResetCredits") or {}).get("credits", []))
    if resets:
        lines.append(f"codex   {resets} free full resets unused")
    return lines


def go():
    with open(f"{CREDS}/opencode") as f:
        key = json.load(f)["opencode-go"]["key"]
    out = get("https://opencode.ai/zen/go/v1/usage", key)["usage"]
    names = {"rolling": "5h", "weekly": "week", "monthly": "month"}
    return [line("go", names[k], out[k]["percent"], out[k]["resetsAt"]) for k in names if out.get(k)]


def shares(rows):
    """Asks usage-share who used each window since its start."""
    windows = {}
    for _, account, window, start in rows:
        windows.setdefault(account, {})[window] = start
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(60)
        s.connect(os.environ["USAGE_SHARE"])
        s.sendall((json.dumps(windows) + "\n").encode())
        s.shutdown(socket.SHUT_WR)
        return json.loads(b"".join(iter(lambda: s.recv(65536), b"")))


def split(spent):
    """korra 71% (memory 12%) · sokka 26% · ... · $14 at API prices"""
    total = sum(spent.values())
    if not total:
        return "        no use logged here"
    agents = {}
    for key, dollars in spent.items():
        agent, _, part = key.partition(" ")
        whole, parts = agents.setdefault(agent, [0, {}])
        agents[agent][0] = whole + dollars
        if part:
            parts[part] = parts.get(part, 0) + dollars
    out = []
    for agent, (whole, parts) in sorted(agents.items(), key=lambda a: -a[1][0]):
        inner = ", ".join(f"{p} {d / total:.0%}" for p, d in parts.items())
        out.append(f"{agent} {whole / total:.0%}" + (f" ({inner})" if inner else ""))
    return "        " + " · ".join(out) + f" · ${total:,.0f} at API prices"


rows = []
for name, read in (("claude", claude), ("codex", codex), ("go", go)):
    try:
        rows += [(r, name) for r in read()]
    except Exception as e:
        rows.append((f"{name:<7} unknown ({type(e).__name__}: {e})", name))
windows = [r for r, _ in rows if isinstance(r, tuple)]
try:
    spent = shares(windows) if windows else {}
except Exception as e:
    spent = {}
    print(f"usage-share unknown ({type(e).__name__}: {e})")
for r, _ in rows:
    if isinstance(r, tuple):
        print(r[0])
        if r[1] in spent:
            print(split(spent[r[1]].get(r[2], {})))
    else:
        print(r)
print("Shares count use logged on Water: the seat, the assistants, their memories and pictures.")
