"""One connection, one report: how much of each subscription's limits is
used, read live from each provider. Claude and OpenCode Go logins arrive as
systemd credentials; Codex runs its own app-server on the household login,
which keeps that login fresh itself. Nothing is stored."""

import json
import os
import subprocess
import sys
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
    return t.strftime("%a %H:%M")


def line(account, window, pct, at):
    return f"{account:<7} {window:<5} {pct:3.0f}%  resets {when(at)}"


def claude():
    with open(f"{CREDS}/claude") as f:
        login = json.load(f)["claudeAiOauth"]
    if login["expiresAt"] / 1000 < time.time():
        return ["claude  unknown (the seat's login lapsed; it renews when the seat next runs claude)"]
    out = get("https://api.anthropic.com/api/oauth/usage", login["accessToken"], {"anthropic-beta": "oauth-2025-04-20"})
    names = {"five_hour": "5h", "seven_day": "week"}
    return [line("claude", names[k], out[k]["utilization"], out[k]["resets_at"]) for k in names if out.get(k)]


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
            lines.append(line("codex", name, w["usedPercent"], w["resetsAt"]))
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


for name, read in (("claude", claude), ("codex", codex), ("go", go)):
    try:
        print("\n".join(read()))
    except Exception as e:
        print(f"{name:<7} unknown ({type(e).__name__}: {e})")
    sys.stdout.flush()
