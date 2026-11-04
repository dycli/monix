"""Evaluates an expression in the app's WebView over DevTools (a debug APK
lets adb reach it) and prints the result. Usage: cdp.py EXPRESSION"""
import base64, json, os, socket, struct, subprocess, sys, urllib.request

def adb(*a):
    return subprocess.run(["adb", *a], capture_output=True, text=True).stdout

name = next((l.split("@")[-1] for l in adb("shell", "cat /proc/net/unix").split() if "webview_devtools_remote" in l), None)
if not name:
    sys.exit("no WebView DevTools socket")
adb("forward", "tcp:9222", "localabstract:" + name)
pages = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json"))
page = next(p for p in pages if "terminal" in p.get("url", ""))
path = page["webSocketDebuggerUrl"].split("9222", 1)[1]
s = socket.create_connection(("127.0.0.1", 9222))
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
rest = buf.split(b"\r\n\r\n", 1)[1]

def send(obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(data)
    head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
    s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

def need(n):
    global rest
    while len(rest) < n:
        rest += s.recv(65536)
    out, rest = rest[:n], rest[n:]
    return out

def recv():
    h = need(2)
    n = h[1] & 127
    if n == 126: n = struct.unpack(">H", need(2))[0]
    elif n == 127: n = struct.unpack(">Q", need(8))[0]
    return json.loads(need(n))

send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": sys.argv[1], "returnByValue": True, "awaitPromise": True}})
while True:
    m = recv()
    if m.get("id") == 1:
        r = m["result"]
        print(json.dumps(r.get("result", {}).get("value", r)))
        break
