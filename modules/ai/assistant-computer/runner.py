"""Run the assistant's code on its computer, with no network.

The assistant on the host lays a run's files in a folder of the desk,
then asks over plain HTTP on the guest's address: POST /run with JSON
{"dir", "language", "code", "seconds"}. The code runs in that folder,
Python or a shell with the converters on its path, and whatever it
writes there the host keeps. The answer is JSON {"exit", "stdout",
"stderr", "timed_out"}.

systemd hands this server its listening socket, so the service itself
can have no network of its own: the code it runs reaches nothing, and
the browser's logins in /home/pc are out of its sight. One run at a
time; the next waits.
"""

import json
import os
import re
import signal
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

RUNS = os.environ["DESK_RUNS"]
# The most of each stream that goes back; the model reads it all.
OUTPUT_MAX = 20_000
SECONDS_MAX = 600
# Linux refuses a longer single argument.
CODE_MAX = 120_000
NAME = re.compile(r"[A-Za-z0-9-]+")


def cut(path: str) -> str:
    with open(path, "rb") as stream:
        text = stream.read(OUTPUT_MAX * 4).decode("utf-8", "replace")
    if len(text) <= OUTPUT_MAX:
        return text
    rest = len(text) - OUTPUT_MAX
    return text[:OUTPUT_MAX] + f"\n(cut: {rest} more characters)"


def run(ask: dict) -> dict:
    name, code = ask.get("dir", ""), ask.get("code", "")
    if not NAME.fullmatch(name):
        raise ValueError("dir must be a plain folder name")
    if len(code) > CODE_MAX:
        raise ValueError(f"code over {CODE_MAX} characters")
    where = os.path.join(RUNS, name)
    command = {
        "python": ["python3", "-c", code],
        "shell": ["bash", "-c", code],
    }.get(ask.get("language"))
    if command is None:
        raise ValueError("language must be python or shell")
    seconds = min(max(int(ask.get("seconds", 120)), 1), SECONDS_MAX)
    scratch = os.path.join(where, ".tmp")
    os.makedirs(scratch, exist_ok=True)
    env = {
        "PATH": os.environ["PATH"],
        "LANG": "C.UTF-8",
        "HOME": where,
        "TMPDIR": scratch,
        "MPLBACKEND": "Agg",
        "MPLCONFIGDIR": scratch,
        # ImageMagick's own limits are far under what the service allows.
        "MAGICK_MEMORY_LIMIT": "1GiB",
    }
    # Output goes to files, not pipes: a pipe a background process holds
    # would keep the run open, and a full one would stall the code.
    out, err = os.path.join(scratch, "stdout"), os.path.join(scratch, "stderr")
    with open(out, "wb") as stdout, open(err, "wb") as stderr:
        child = subprocess.Popen(
            command,
            cwd=where,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
    timed_out = False
    try:
        child.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
    # Whatever it left running in the background goes with it.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()
    return {
        "exit": child.returncode,
        "stdout": cut(out),
        "stderr": cut(err),
        "timed_out": timed_out,
    }


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        if self.path != "/run":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            answer = run(json.loads(self.rfile.read(length)))
        except (ValueError, TypeError, OSError) as error:
            self.reply(400, "text/plain", str(error).encode())
            return
        self.reply(200, "application/json", json.dumps(answer).encode())

    def reply(self, status: int, kind: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    # Files the code writes stay the desk group's to read and remove.
    os.umask(0o007)
    if os.environ.get("LISTEN_FDS") != "1":
        sys.exit("runner: expects one socket from systemd")
    server = HTTPServer(("", 0), Handler, bind_and_activate=False)
    server.socket = socket.socket(fileno=3)
    server.serve_forever()


if __name__ == "__main__":
    main()
