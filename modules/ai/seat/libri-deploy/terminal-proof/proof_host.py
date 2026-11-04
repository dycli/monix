"""Usage rings fixtures: the scenario is read from /tmp/usage-fixture each
request (both, week, none), and the page is served from DIST when set.
A scripted Libri host for the Android app's emulator checks: answers
the read endpoints with fixed data and, on each /api/run, streams a turn
with thinking, a tool call, a question, jobs, a mail draft and a reply."""
import base64, hashlib, json, math, queue, struct, threading, time, sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

subscribers = []
history = [
    {"i": 1, "kind": "user", "text": "earlier question", "date": "2026-10-29T21:00:00-04:00", "reaction": None},
    {"i": 2, "kind": "talk", "text": "## Heading\n\n- one\n- **two**\n\n```\ncode block\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |", "date": "2026-10-29T21:00:05-04:00", "reaction": "👍"},
    {"i": 3, "kind": "user", "text": "Routine r1 set, due now: water the plants every morning before work", "date": "2026-10-29T21:01:00-04:00", "reaction": None},
]
# A long thread, so following its foot means something.
for n in range(140):
    i = 10 + 2 * n
    history.append({"i": i, "kind": "user", "text": f"question {n}", "date": "2026-10-29T21:05:00-04:00", "reaction": None})
    history.append({"i": i + 1, "kind": "talk", "text": f"Answer {n}. " + "Some words to fill the line and take up room on the page. " * (1 + n % 7), "date": "2026-10-29T21:05:05-04:00", "reaction": None})
# Real histories carry their calls, and their calls' output, too.
for n in range(60):
    i = 400 + 4 * n
    history.append({"i": i, "kind": "user", "text": f"more {n}", "date": "2026-10-29T21:06:00-04:00", "reaction": None})
    history.append({"i": i + 1, "kind": "tool", "text": 'Bash {"command":"ls"}', "date": "2026-10-29T21:06:01-04:00", "reaction": None})
    history.append({"i": i + 2, "kind": "echo", "text": "output line\n" * 300, "date": "2026-10-29T21:06:02-04:00", "reaction": None})
    history.append({"i": i + 3, "kind": "talk", "text": f"Reply {n}.", "date": "2026-10-29T21:06:03-04:00", "reaction": None})
threads = [
    {"id": "Ada", "name": "Ada", "brief": "Research the options for the garden", "state": "working", "at": int(time.time()) - 300, "read": False},
    {"id": "Bo", "name": "Bo", "brief": "Write the report", "state": "waiting", "at": int(time.time()) - 3600, "report": "Done: the report is in the library.", "read": False},
    {"id": "Dee", "name": "Dee", "brief": "Crashed before reporting", "state": "waiting", "at": int(time.time()) - 200000, "read": False},
    {"id": "Eli", "name": "Eli", "brief": "Slept on it", "state": "sleeping", "at": int(time.time()) - 86400 * 9, "report": "All in hand.", "read": True},
    {"id": "Cy", "name": "Cy", "brief": "Old task", "state": "archived", "at": int(time.time()) - 86400, "read": True},
]
log = "1|user: Research the options for the garden\n2|talk: Looking.\n3|tool: Bash {\"command\":\"ls garden\"}\n4|echo: beds paths\n5|talk: Two beds and a path."
log += "".join(f"\n{6 + 2 * n}|tool: Bash {{\"command\":\"step {n}\"}}\n{7 + 2 * n}|echo: ok" for n in range(60))
scratched = []
summ = {"picked": None, "effective": {"name": "Haiku", "harness": "claude", "model": "claude-haiku-5-5"}, "error": None, "last": {"ok": True, "at": "x", "name": "Haiku", "error": None},
        "options": [{"name": "Haiku", "note": "Cheap and good.", "default": True, "reachable": True, "harness": "claude", "model": "claude-haiku-5-5"}, {"name": "DeepSeek Flash", "note": "Cheapest.", "default": False, "reachable": False, "harness": None, "model": None}]}
links = {"fastmail": None, "xai": None, "xai_signing": None, "xai_said": None}
polls = [0]
saved_voice = ["eve"]
worker_choice = {"pick": {"harness": "codex", "model": "gpt-6.1-terra"}, "effort": "xhigh", "access": "ask", "sandbox": "workspace"}
main_pick = {"pick": {"harness": "claude", "model": "opus"}, "effort": ""}
told_held = []
temp_pick = {"pick": {"harness": "claude", "model": "opus"}, "effort": ""}
# A host no model was ever picked on: argv[2] == "unpicked".
if sys.argv[2:] == ["unpicked"]:
    for chosen in (worker_choice, main_pick, temp_pick):
        chosen["pick"]["model"] = ""

shown = [True]
def usage_now():
    import os
    try: scene = open("/tmp/usage-fixture").read().strip()
    except OSError: scene = "both"
    w = lambda window, name, hours, pct, resets: {"window": window, "name": name, "hours": hours, "pct": pct, "resets": resets}
    claude = {"both": [w("5h", "5 hours", 5, 40, "Tue Nov 3 14:59"), w("week", "Week", 168, 92, "Sun Nov 8 17:00")],
              "week": [w("week", "Week", 168, 22, "Sun Nov 8 17:00")], "none": []}[scene]
    accounts = [
        {"account": "claude", "name": "Claude", "windows": claude, "notes": ["libri 81% · suki 19% · $24 at API prices"]},
        {"account": "codex", "name": "ChatGPT", "windows": [w("5h", "5 hours", 5, 75, "Tue Nov 3 14:59"), w("week", "Week", 168, 9, "Wed Nov 4 06:36")], "notes": ["no use logged here", "3 free full resets unused"]},
        {"account": "go", "name": "OpenCode Go", "windows": [w("5h", "5 hours", 5, 0, "Tue Nov 3 14:59"), w("week", "Week", 168, 7, "Sun Nov 8 19:00"), w("month", "Month", 720, 11, "Tue Nov 24 08:28")], "notes": []},
        {"account": "boat", "name": "boat.dev", "windows": [w("month", "Month", 720, 28, "Mon Nov 30 18:41")], "notes": ["$5.61 of $20 included, wallet $0.00, 3 running"]},
    ]
    if scene == "none":
        accounts = [a for a in accounts if a["account"] != "claude"]
    return {"shown": shown[0], "accounts": accounts, "notes": ["Shares count use logged on Water: the seat, the assistants, their memories and pictures."]}

def emit(e):
    for q in list(subscribers):
        q.put(e)

def turn(text):
    def go():
        mid = "a1"
        steps = [
            {"type": "RUN_STARTED"},
            {"type": "REASONING_MESSAGE_CONTENT", "delta": "Thinking about the garden.\nWeighing the beds."},
            {"type": "TEXT_MESSAGE_START", "messageId": mid},
            {"type": "TEXT_MESSAGE_CONTENT", "messageId": mid, "delta": "Let me look."},
            {"type": "TOOL_CALL_START", "toolCallId": "t1", "toolCallName": "Bash", "parentMessageId": mid},
            {"type": "TOOL_CALL_ARGS", "toolCallId": "t1", "delta": "{\"command\":\"ls /srv\"}"},
            {"type": "TOOL_CALL_END", "toolCallId": "t1"},
            {"type": "ACTIVITY_SNAPSHOT", "activityType": "jobs", "messageId": "jobs", "content": {"names": ["build"]}},
            {"type": "TOOL_CALL_RESULT", "toolCallId": "t1", "content": "storage\nwww"},
            {"type": "ACTIVITY_SNAPSHOT", "activityType": "approval", "messageId": "act-7", "content": {"id": 7, "act": {"kind": "mail", "account": "dylan@dylanc.com", "to": "gab@example.com", "subject": "Dinner", "body": "Shall we eat at seven?"}, "event": None}},
            {"type": "RUN_FINISHED", "outcome": {"type": "interrupt", "interrupts": [{"id": "q1", "reason": "tool", "metadata": {"tool": "AskUserQuestion", "input": {"questions": [{"question": "Which bed first?", "header": "Garden", "multiSelect": False, "options": [{"label": "North", "description": "sunnier"}, {"label": "South"}]}]}}}]}},
        ]
        if text.startswith("@ask-tool"):
            steps[-1] = {"type": "RUN_FINISHED", "outcome": {"type": "interrupt", "interrupts": [{"id": "q2", "reason": "tool", "message": "Removes the old logs.", "metadata": {"tool": "Bash", "input": {"command": "rm -r /tmp/logs"}}}]}}
        for e in steps:
            time.sleep(0.6)
            emit(e)
    threading.Thread(target=go, daemon=True).start()

def stream(jobs=False):
    """A turn that goes slowly: dots, a tool row, then a long answer word by word.
    `jobs`: a running job stays under the answer, as a build does."""
    def go():
        slow = [(3.0, {"type": "RUN_STARTED"}),
                *([(0.2, {"type": "ACTIVITY_SNAPSHOT", "activityType": "jobs", "messageId": "jobs", "content": {"names": ["build"]}})] if jobs else []),
                (2.0, {"type": "TEXT_MESSAGE_START", "messageId": "s1"}),
                (0.2, {"type": "TEXT_MESSAGE_CONTENT", "messageId": "s1", "delta": "Looking."}),
                (0.2, {"type": "TOOL_CALL_START", "toolCallId": "s-t1", "toolCallName": "Bash", "parentMessageId": "s1"}),
                (0.2, {"type": "TOOL_CALL_ARGS", "toolCallId": "s-t1", "delta": "{\"command\":\"sleep 3\"}"}),
                (0.2, {"type": "TOOL_CALL_END", "toolCallId": "s-t1"}),
                (3.0, {"type": "TOOL_CALL_RESULT", "toolCallId": "s-t1", "content": "ok"}),
                (0.2, {"type": "TEXT_MESSAGE_START", "messageId": "s2"})]
        for wait, e in slow:
            emit(e); time.sleep(wait)
        for n in range(400):
            emit({"type": "TEXT_MESSAGE_CONTENT", "messageId": "s2", "delta": f"word{n} " + ("\n\n" if n % 40 == 39 else "")})
            time.sleep(0.08)
        emit({"type": "TEXT_MESSAGE_END", "messageId": "s2"})
        emit({"type": "RUN_FINISHED", "outcome": {"type": "success"}})
    threading.Thread(target=go, daemon=True).start()

turn_now = {"typing": False, "shown": [], "start": 0}

def track(e):
    """As the host: emits an event and keeps it in the turn's record."""
    turn_now["shown"].append(e)
    emit(e)
    if e["type"] == "TEXT_MESSAGE_CONTENT": sys.stderr.write(f"T {time.time():.2f} words {e['delta']}\n")

def said_now(kind, text):
    history.append({"i": history[-1]["i"] + 1, "kind": kind, "text": text, "date": time.strftime("%Y-%m-%dT%H:%M:%S-04:00"), "reaction": None})

def call_events(cid, name, args, parent=None):
    start = {"type": "TOOL_CALL_START", "toolCallId": cid, "toolCallName": name}
    if parent: start["parentMessageId"] = parent
    return [(0.1, start), (0.1, {"type": "TOOL_CALL_ARGS", "toolCallId": cid, "delta": json.dumps(args)}), (1.6, {"type": "TOOL_CALL_END", "toolCallId": cid}), (0.2, {"type": "TOOL_CALL_RESULT", "toolCallId": cid, "content": "ok"})]

def words_events(mid, text):
    return [(0.1, {"type": "TEXT_MESSAGE_START", "messageId": mid}), (0.4, {"type": "TEXT_MESSAGE_CONTENT", "messageId": mid, "delta": text})]

def runs_turn(person, tag, slow=1):
    """Words, 2 calls, words, 2 calls, words, 1 call, final words."""
    def go():
        turn_now.update(typing=True, shown=[], start=int(time.time() * 1000))
        track({"type": "TEXT_MESSAGE_CHUNK", "role": "user", "messageId": person[0], "delta": person[1]})
        track({"type": "RUN_STARTED"})
        said = [("talk", f"First words {tag}."), ("tool", 'Bash {"command":"ls a"}'), ("echo", "ok"), ("tool", 'Bash {"command":"ls b"}'), ("echo", "ok"),
                ("talk", f"Second words {tag}."), ("tool", 'Read {"file_path":"/tmp/c"}'), ("echo", "ok"), ("tool", 'Grep {"pattern":"d"}'), ("echo", "ok"),
                ("talk", f"Third words {tag}."), ("tool", 'Bash {"command":"ls e"}'), ("echo", "ok"), ("talk", f"Final words {tag}.")]
        steps = (words_events(tag + "1", f"First words {tag}.") + call_events(tag + "a", "Bash", {"command": "ls a"}, tag + "1") + call_events(tag + "b", "Bash", {"command": "ls b"}, tag + "1")
                 + words_events(tag + "2", f"Second words {tag}.") + call_events(tag + "c", "Read", {"file_path": "/tmp/c"}, tag + "2") + call_events(tag + "d", "Grep", {"pattern": "d"}, tag + "2")
                 + words_events(tag + "3", f"Third words {tag}.") + call_events(tag + "e", "Bash", {"command": "ls e"}, tag + "3")
                 + words_events(tag + "4", f"Final words {tag}."))
        for wait, e in steps:
            track(e); time.sleep(wait * slow)
        track({"type": "TEXT_MESSAGE_END", "messageId": tag + "4"})
        said_now("user", person[1])
        for k, t in said: said_now(k, t)
        track({"type": "RUN_FINISHED", "outcome": {"type": "success"}})
        turn_now.update(typing=False, shown=[], start=0)
    threading.Thread(target=go, daemon=True).start()

def wake_turn(person, tag):
    """A reply that ends its turn, then a wake-up's calls and words."""
    def go():
        turn_now.update(typing=True, shown=[], start=int(time.time() * 1000))
        track({"type": "TEXT_MESSAGE_CHUNK", "role": "user", "messageId": person[0], "delta": person[1]})
        track({"type": "RUN_STARTED"})
        for wait, e in words_events(tag + "1", f"Finished reply {tag}."): track(e); time.sleep(wait)
        track({"type": "TEXT_MESSAGE_END", "messageId": tag + "1"})
        track({"type": "RUN_FINISHED", "outcome": {"type": "success"}})
        said_now("user", person[1]); said_now("talk", f"Finished reply {tag}.")
        turn_now.update(typing=False, shown=[], start=0)
        time.sleep(9)
        turn_now.update(typing=True, shown=[], start=int(time.time() * 1000))
        track({"type": "RUN_STARTED"})
        for wait, e in call_events(tag + "a", "Bash", {"command": "ls w1"}) + call_events(tag + "b", "Bash", {"command": "ls w2"}) + words_events(tag + "2", f"After waking {tag}."):
            track(e); time.sleep(wait)
        track({"type": "TEXT_MESSAGE_END", "messageId": tag + "2"})
        for k, t in [("tool", 'Bash {"command":"ls w1"}'), ("echo", "ok"), ("tool", 'Bash {"command":"ls w2"}'), ("echo", "ok"), ("talk", f"After waking {tag}.")]: said_now(k, t)
        track({"type": "RUN_FINISHED", "outcome": {"type": "success"}})
        turn_now.update(typing=False, shown=[], start=0)
    threading.Thread(target=go, daemon=True).start()

def storm(secs):
    """The host's empty runs, seen live at about 7 a second."""
    def go():
        end = time.time() + secs
        n = 0
        while time.time() < end:
            n += 1
            emit({"type": "RUN_STARTED", "threadId": "main", "runId": f"run-{n}"}); time.sleep(0.07)
            emit({"type": "RUN_FINISHED", "threadId": "main", "runId": f"run-{n}", "outcome": {"type": "success"}}); time.sleep(0.07)
    threading.Thread(target=go, daemon=True).start()

def busy_turn(person):
    """Reasoning, then call after call, with a worker's events between."""
    def go():
        emit({"type": "TEXT_MESSAGE_CHUNK", "role": "user", "messageId": person[0], "delta": person[1]})
        emit({"type": "RUN_STARTED"})
        n = 0
        def worker():
            emit({"type": "TEXT_MESSAGE_CONTENT", "subagentRunId": "Ada", "messageId": "w", "delta": "x"})
        for c in range(7):
            for i in range(10):
                emit({"type": "REASONING_MESSAGE_CONTENT", "messageId": f"th{c}", "delta": f"thinking {i} "}); worker(); time.sleep(0.09)
            cid = f"b{c}"
            emit({"type": "TOOL_CALL_START", "toolCallId": cid, "toolCallName": "Bash"})
            emit({"type": "TOOL_CALL_ARGS", "toolCallId": cid, "delta": json.dumps({"command": f"step {c}"})})
            emit({"type": "TOOL_CALL_END", "toolCallId": cid})
            time.sleep(1.0)
            emit({"type": "TOOL_CALL_RESULT", "toolCallId": cid, "content": "ok"})
            time.sleep(0.6)
        emit({"type": "TEXT_MESSAGE_START", "messageId": "bf"})
        for w in "All steps done and nothing else to report here.".split():
            emit({"type": "TEXT_MESSAGE_CONTENT", "messageId": "bf", "delta": w + " "}); time.sleep(0.1)
        emit({"type": "TEXT_MESSAGE_END", "messageId": "bf"})
        emit({"type": "RUN_FINISHED", "outcome": {"type": "success"}})
    threading.Thread(target=go, daemon=True).start()

def finish():
    def go():
        for e in [
            {"type": "RUN_STARTED"},
            {"type": "TEXT_MESSAGE_START", "messageId": "a2"},
            *({"type": "TEXT_MESSAGE_CONTENT", "messageId": "a2", "delta": w} for w in "North it is. **Done** with `ls`.".split(" ") for w in [w + " "]),
            {"type": "TEXT_MESSAGE_END", "messageId": "a2"},
            {"type": "RUN_FINISHED", "outcome": {"type": "success"}},
        ]:
            time.sleep(0.3)
            emit(e)
    threading.Thread(target=go, daemon=True).start()

def ws_read(r):
    """One client frame: its opcode and payload."""
    head = r.read(2)
    if len(head) < 2:
        return None, b""
    op, n = head[0] & 15, head[1] & 127
    if n == 126: n = struct.unpack(">H", r.read(2))[0]
    elif n == 127: n = struct.unpack(">Q", r.read(8))[0]
    mask = r.read(4)
    data = bytearray(r.read(n))
    for i in range(n): data[i] ^= mask[i % 4]
    return op, bytes(data)

def ws_send(w, op, data):
    n = len(data)
    head = bytes([0x80 | op]) + (bytes([n]) if n < 126 else b"\x7e" + struct.pack(">H", n) if n < 65536 else b"\x7f" + struct.pack(">Q", n))
    w.write(head + data); w.flush()

def realtime(h):
    """The voice service: greets, plays a second of tone, hears a line."""
    key = base64.b64encode(hashlib.sha1((h.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    h.send_response(101)
    h.send_header("Upgrade", "websocket"); h.send_header("Connection", "Upgrade"); h.send_header("Sec-WebSocket-Accept", key)
    h.send_header("Sec-WebSocket-Protocol", h.headers.get("Sec-WebSocket-Protocol", ""))
    h.end_headers()
    frames = 0
    say = lambda e: ws_send(h.wfile, 1, json.dumps(e).encode())
    while True:
        op, data = ws_read(h.rfile)
        if op is None or op == 8:
            sys.stderr.write(f"REALTIME closed, mic frames {frames}\n")
            return
        if op == 2:
            frames += 1
            # Twenty seconds in, as server_vad hearing the person: their words,
            # then the voice answers. Nothing is said before that.
            if frames == 1000:
                sys.stderr.write("REALTIME the person speaks\n")
                say({"type": "input_audio_buffer.speech_started"})
                say({"type": "input_audio_buffer.committed", "item_id": "u1"})
                say({"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "the mock heard this"})
                say({"type": "response.output_audio_transcript.delta", "item_id": "t1", "delta": "Hello from the mock voice."})
                tone = b"".join(struct.pack("<h", int(8000 * math.sin(i / 24000 * 2 * math.pi * 440))) for i in range(24000))
                for i in range(0, len(tone), 4800): ws_send(h.wfile, 2, tone[i:i + 4800])
                say({"type": "response.output_audio_transcript.done", "item_id": "t1", "transcript": "Hello from the mock voice."})
        elif op == 1:
            e = json.loads(data)
            sys.stderr.write(f"REALTIME {data[:400]!r}\n")

def terminal(h):
    """The host's shell: a screen of numbered lines ending in a prompt; every
    size the client sends is logged, and typed bytes are echoed."""
    key = base64.b64encode(hashlib.sha1((h.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    h.send_response(101)
    h.send_header("Upgrade", "websocket"); h.send_header("Connection", "Upgrade"); h.send_header("Sec-WebSocket-Accept", key)
    h.end_headers()
    first = True
    while True:
        op, data = ws_read(h.rfile)
        if op is None or op == 8:
            return
        if op == 1:
            sys.stderr.write(f"TERMINAL size {data.decode()}\n")
            if first:
                first = False
                screen = "\r\n".join(f"line {i:02d} " + "abcdefghij" * 7 for i in range(1, 61)) + "\r\nLAST LINE\r\nPROMPT$ "
                ws_send(h.wfile, 2, screen.encode())
        elif op == 2:
            ws_send(h.wfile, 2, data)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        sys.stderr.write(f"{time.time():.2f} " + " ".join(map(str, a)) + "\n")

    def send(self, body, code=200):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p = self.path.split("?")[0]
        import os
        dist = os.environ.get("DIST")
        if dist and not p.startswith(("/api", "/realtime", "/login")):
            f = os.path.join(dist, p.lstrip("/") or "index.html")
            if not os.path.isfile(f): f = os.path.join(dist, "index.html")
            kind = {"js": "text/javascript", "css": "text/css", "html": "text/html", "svg": "image/svg+xml", "png": "image/png", "json": "application/json", "woff2": "font/woff2", "webmanifest": "application/manifest+json"}.get(f.rsplit(".", 1)[-1], "application/octet-stream")
            data = open(f, "rb").read()
            self.send_response(200); self.send_header("content-type", kind); self.send_header("content-length", str(len(data))); self.end_headers(); self.wfile.write(data)
            return
        sys.stderr.write(f"T {time.time():.2f} GET {self.path}\n")
        if p == "/realtime":
            return realtime(self)
        if p == "/api/terminal":
            return terminal(self)
        if p == "/api/host":
            return self.send({"id": "mock", "name": "Mock", "version": "0.1.0", "uptime": 42, "url": None, "addresses": ["127.0.0.1:8973"]})
        if p == "/api/history":
            return self.send(history)
        if p == "/api/task":
            sys.stderr.write(f"T {time.time():.2f} read task, {len(turn_now['shown'])} shown\n")
            return self.send({"typing": turn_now["typing"], "turn": {"start": turn_now["start"], "shown": turn_now["shown"]} if turn_now["typing"] else None, "agents": []})
        if p == "/api/pending":
            return self.send([])
        if p == "/api/me":
            return self.send({"app": "Libri", "name": "Mock", "voice": saved_voice[0] if links["xai"] else None, "forgets": [60, 1440], "models": True, "personas": []})
        if p == "/api/models":
            return self.send({**main_pick, "temp": temp_pick, "access": "auto", "modes": [{"harness": "codex", "access": [{"id": "ask", "name": "Ask first", "note": "", "open": False}, {"id": "full", "name": "Full access", "note": "", "open": True}],
                "sandbox": [{"id": "workspace", "name": "Workspace", "note": "", "open": False}, {"id": "none", "name": "No sandbox", "note": "", "open": True}]}], "others": "opencode", "othersOffered": ["opencode", "omp"], "offers": [
                {"harness": "claude", "model": "opus", "name": "Opus 5.5", "provider": "anthropic", "efforts": ["low", "high", "max"], "default": True, "usage": "claude"},
                {"harness": "codex", "model": "gpt", "name": "GPT-6", "provider": "openai", "efforts": ["low", "high"], "default": False, "usage": "codex"},
                {"harness": "codex", "model": "gpt-6.1-terra", "name": "GPT-6.1 Terra", "provider": "openai", "efforts": ["minimal", "low", "medium", "high", "xhigh"], "default": False, "usage": "codex"},
                {"harness": "opencode", "model": "deepseek/flash", "name": "DeepSeek Flash", "provider": "deepseek", "efforts": [], "default": False, "usage": None}]})
        if p.startswith("/api/speak/"):
            pcm = b"".join(struct.pack("<h", int(6000 * math.sin(i / 8000 * 2 * math.pi * 330))) for i in range(8000 * 60))
            wav = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm
            self.send_response(200); self.send_header("content-type", "audio/wav"); self.send_header("content-length", str(len(wav))); self.end_headers(); self.wfile.write(wav)
            return
        if p == "/api/voices":
            return self.send([{"id": "eve", "name": "Eve"}, {"id": "ara", "name": "Ara"}, {"id": "rex", "name": "Rex"}])
        if p == "/api/capabilities":
            return self.send({"fixed": [{"capability": "X search", "model": "grok-4.7", "name": "grok-4.7", "provider": "xai"}], "image": {"choices": [{"model": "grok-imagine-image-2.0", "name": "Grok Imagine 2.0", "provider": "xai"}], "picked": {"model": "grok-imagine-image-2.0", "name": "Grok Imagine 2.0", "provider": "xai"}}})
        if p == "/api/connections":
            if links["xai_signing"]:
                polls[0] += 1
                if polls[0] >= 3:
                    links["xai"] = "Grok sign-in"; links["xai_signing"] = None
            return self.send(links)
        if p == "/api/summarizer":
            import os
            if os.path.exists("/tmp/ivo-sum-gone"): return self.send({}, 404)
            if os.path.exists("/tmp/ivo-sum-else"): return self.send({"elsewhere": True, "options": []})
            return self.send(summ)
        if p == "/api/usage":
            return self.send([])  # main's list form; usage rings are Skye's branch
        if p == "/api/work":
            return self.send({"threads": threads})
        if p.endswith("/choice"):
            return self.send(worker_choice)
        if p.startswith("/api/work/"):
            return self.send({"text": log})
        if p == "/api/past":
            return self.send([{"id": 0, "n": 4096, "text": "user: launched the ship; talk: built Libri"}])
        if p.startswith("/api/zoom/"):
            return self.send({"parts": [{"id": 0, "n": 2048, "text": "first half"}, {"id": 2048, "n": 2048, "text": "second half"}]})
        if p == "/api/forget":
            return self.send({"minutes": 1440})
        if p == "/api/signin":
            return self.send({"claude": True, "codex": False})
        if p == "/api/events":
            sys.stderr.write(f"T {time.time():.2f} stream opens\n")
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            q = queue.Queue()
            subscribers.append(q)
            try:
                while True:
                    try:
                        e = q.get(timeout=10)
                        self.wfile.write(f"data: {json.dumps(e)}\n\n".encode())
                    except queue.Empty:
                        self.wfile.write(b":\n\n")
                    self.wfile.flush()
            except Exception:
                subscribers.remove(q)
            return
        self.send({}, 404)

    def do_POST(self):
        global log
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n)
        p = self.path
        sys.stderr.write(f"POST {p} {body[:300]!r}\n")
        if p == "/mock/main":
            # Main's tell_agent: written to the log bare.
            log += f"\n{1000 + log.count(chr(10))}|user: {body.decode()}"
            return self.send({})
        if p == "/mock/read":
            # A running worker reads what it was told, between its calls.
            log += "".join(f"\n{1000 + log.count(chr(10)) + n}|user: {line}" for n, line in enumerate(told_held))
            told_held.clear()
            return self.send({})
        if p.endswith("/tell") and b"refuse" in body:
            # The host turning a tell away, late, so a second can pass it in flight.
            time.sleep(9)
            return self.send({"error": "Told, but not kept"}, 502)
        if p.endswith("/tell"):
            b = json.loads(body)
            said = b["text"] if not b.get("files") else f"(sent a photo: shot.png) {b['text']}".rstrip()
            line = f"(From the person, typed on your page) {said}"
            if "hold" in b["text"]:
                told_held.append(line)
                return self.send({})
            log += f"\n{1000 + log.count(chr(10))}|user: {line}"
        if p == "/api/usage":
            shown[0] = json.loads(body)["shown"]
            return self.send({})
        if p == "/api/run":
            r = json.loads(body)
            if r.get("resume"):
                finish()
            else:
                m = r["messages"][0]
                text = m["content"] if isinstance(m["content"], str) else m["content"][0]["text"]
                if not text.startswith(("runs ", "wake ", "busy", "steps")):
                    emit({"type": "TEXT_MESSAGE_CHUNK", "role": "user", "messageId": m["id"], "delta": text})
                if text.startswith("steps"):
                    for n in range(3):
                        emit({"type": "TOOL_CALL_START", "subagentRunId": "Ada", "toolCallId": f"sw{n}", "toolCallName": "Bash"})
                    return self.send({})
                if text.startswith("storm"):
                    storm(14)
                    return self.send({})
                if text.startswith("busy"):
                    busy_turn((m["id"], text))
                    return self.send({})
                if text.startswith("runs "):
                    return runs_turn((m["id"], text), text.split()[1], float((text.split() + ["1"])[2])) or self.send({})
                if text.startswith("wake "):
                    return wake_turn((m["id"], text), text.split()[1]) or self.send({})
                stream(jobs="jobs" in text) if text.startswith("stream") else turn(text)
            return self.send({})
        if p == "/api/decide":
            emit({"type": "ACTIVITY_DELTA", "activityType": "approval", "messageId": "act-7", "patch": [{"op": "add", "path": "/outcome", "value": {"text": "Mail sent to gab@example.com.", "done": True}}]})
            return self.send({})
        if p == "/api/scratch":
            turns = json.loads(body)["turns"]
            return self.send({"text": f"Temp answer to: {turns[-1]['text']} ({len(turns)} turns)"})
        if p in ("/api/model", "/api/effort"):
            b = json.loads(body); to = temp_pick if b.get("temp") else main_pick
            if p == "/api/model": to["pick"] = {"harness": b["harness"], "model": b["model"]}
            else: to["effort"] = b["effort"]
            return self.send({})
        if p == "/api/speak":
            time.sleep(2)  # The host makes the speech first: the pill's loading.
            return self.send({"key": "0123456789abcdef"})
        if p == "/api/call":
            return self.send({"secret": "s3cret", "voice": "eve", "instructions": "Be brief.", "url": "ws://10.0.2.2:8973/realtime"})
        if p == "/api/call/end":
            return self.send({})
        if p == "/api/transcribe":
            sys.stderr.write(f"TRANSCRIBE {self.headers.get('content-type')} {len(body)} bytes\n")
            open("/tmp/ivo-dictated.m4a", "wb").write(body)
            time.sleep(1.5)  # Long enough to see the button wait.
            say = open("/tmp/ivo-say").read()
            if say == "502":
                self.send_response(502); self.send_header("content-length", "0"); self.end_headers()
                return
            return self.send({"text": say})
        if p.startswith("/api/work/") and p.endswith("/read"):
            for t in threads:
                if t["name"] == p.split("/")[3]:
                    t["read"] = True
                    if t["state"] == "waiting": t["state"] = "sleeping"
            return self.send({})
        if p == "/api/upload":
            return self.send({"id": "u1"})
        if p.endswith("/choice"):
            import os
            if os.path.exists("/tmp/ivo-refuse"):
                b = b"That model is not on offer."
                self.send_response(400); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
                return
            worker_choice.update(json.loads(body))
            return self.send(worker_choice)
        if p == "/api/summarizer":
            n = json.loads(body)["name"]
            if n == "DeepSeek Flash":
                b = b"DeepSeek Flash is not connected."
                self.send_response(400); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
                return
            summ["picked"] = n
            return self.send(summ)
        if p == "/api/connections/xai":
            polls[0] = 0
            links["xai_signing"] = {"url": "https://example.com/oauth2/device?user_code=XT4N-XMQH", "code": "XT4N-XMQH"}
            return self.send({})
        if p == "/api/connections/xai/key":
            k = json.loads(body)["key"]
            if not k.startswith("xai-"):
                b = b"That doesn't look like an xAI key."
                self.send_response(400); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
                return
            links["xai"] = "API key"
            return self.send({})
        if p == "/api/connections/xai/drop":
            links["xai"] = None
            return self.send({})
        if p == "/api/voice":
            saved_voice[0] = json.loads(body)["voice"]
            return self.send({})
        if p == "/api/connections/fastmail":
            return self.send({"url": "https://example.com/fastmail-signin"})
        if p.startswith("/api/work/") or p.startswith("/api/agent/") or p in ("/api/others", "/api/capabilities", "/api/connections/fastmail/finish", "/api/stop", "/api/model", "/api/effort", "/api/access", "/api/forget"):
            return self.send({})
        self.send({}, 404)

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8973), H).serve_forever()
