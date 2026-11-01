"""remote_run: run a heavy command on a fresh boat.dev sandbox instead of on
Water, and leave no sandbox behind.

    remote_run [--size large] [--ttl 3h] [--fetch PATH]... [--include PATH]... -- COMMAND
    remote_run check                      the repository's full flake check
    remote_run refresh-base [WORKTREE]... rebuild the base snapshot from nothing

The worktree's tracked files, with uncommitted edits, go to ~/work on the
sandbox, and a flake's locked inputs go by `nix flake archive`, so the sandbox
needs no GitHub credentials. No keys go at all: sandboxes are created with
noEnv, and the API key stays here. See remote-build.md in the bridge notes."""

import argparse
import fcntl
import http.client
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

# The builder. The steps after start() only ever see an ssh destination, so the
# build machine replaces boat here and in start().
BUILDER = "http://boat/api/v1"
# nginx adds the API key on this socket, and allows only the calls made here;
# boat.mod.nix holds the list. The seat never holds the key.
SOCKET = os.environ.get("BOAT_SOCKET", "/run/boat-proxy/boat.sock")
# The saved snapshot every run starts from.
BASE = "nix-base"
# Sandboxes at once, counting every active one on the account; runs past this queue.
CEILING = 20
SIZE = "large"
TTL = "3h"
# A cold refresh is about two hours; a run that dies leaves the sandbox stopping here.
REFRESH_TTL = "8h"
# Worktrees whose checks seed the base.
SEEDS = ("~/ark/monix", "~/ark/libri")
# Each seed's commands beyond its flake check, by repository name.
SEED_SHELLS = {"libri": ("nix develop .#android -c true", "nix develop .#android-emulator -c true")}

# Every sandbox of ours is named from this. Names and not labels mark them,
# because a create with `from` drops its labels without saying so.
PREFIX = "remote-run-"
USER = "user"
NIX_PROFILE = "/nix/var/nix/profiles/default"
STATE = Path(os.environ.get("XDG_STATE_HOME", "~/.local/state")).expanduser() / "remote_run"
# What this script exits with for its own failures, as `docker run` does.
FAILED = 125
# How long a job may lose its connection before the run gives up on the sandbox.
RECONNECT_SECONDS = 300
# Boat scrubs withheld secrets from a fork before it lets a key in, seen past
# 300s when several forks start together.
START_SECONDS = 1800
LOG_DAYS = 14

# The installer rewrites nix.conf, so the settings go in after it. 16 GB holds
# two jobs: four ran `nix flake check` out of memory. min-free collects garbage
# rather than failing a check when a flake update outgrows the disk left by
# the base.
BOOTSTRAP = r"""
set -eu
sh <(curl -fsSL https://nixos.org/nix/install) --daemon --yes --nix-extra-conf-file /dev/null </dev/null >nix-install.log 2>&1
sudo tee /etc/nix/nix.conf >/dev/null <<CONF
build-users-group = nixbld
experimental-features = nix-command flakes pipe-operators
trusted-users = root user
accept-flake-config = false
substituters = https://cache.nixos.org https://nix-community.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
warn-dirty = false
system-features = benchmark big-parallel kvm nixos-test uid-range
max-jobs = 2
cores = 4
log-lines = 40
min-free = 8589934592
max-free = 21474836480
CONF
sudo systemctl restart nix-daemon
"""

# Every sandbox boots with /dev/kvm closed to the Nix build users. A fork's
# daemon socket comes up 644 root and goes dead when hydration ends; only a
# restart after hydration cures it. Both socket lines go when a boat restore
# keeps the socket systemd made.
PREPARE = r"""
sudo chmod 666 /dev/kvm
[[ -e {profile} ]] || exit 0
sudo systemctl restart nix-daemon.socket
sudo chmod 666 /nix/var/nix/daemon-socket/socket
"""

# Runs detached, so a dropped connection costs a reconnect and not the job.
JOB = r"""
[[ -e {profile}/etc/profile.d/nix-daemon.sh ]] && . {profile}/etc/profile.d/nix-daemon.sh
(
  peak=0
  while :; do
    used=$(awk '/MemTotal/{{t=$2}}/MemAvailable/{{a=$2}}END{{print int((t-a)/1024)}}' /proc/meminfo)
    ((used > peak)) && peak=$used && echo "$peak" >~/job.peak
    sleep 5
  done
) &
sampler=$!
cd ~/work/{prefix}
bash -c {command} </dev/null
rc=$?
kill "$sampler"
echo "$rc" >~/job.rc.part
mv ~/job.rc.part ~/job.rc
"""

# Prints the job's log from an offset until the job has ended.
ATTACH = r"""
tail -c +{offset} -F ~/job.log 2>/dev/null &
tailer=$!
until [[ -e ~/job.rc ]]; do sleep 2; done
sleep 1
kill "$tailer"
"""


class Failure(Exception):
    pass


class Stopped(BaseException):
    """A signal, carried to main so the sandbox goes on the way out."""

    def __init__(self, signum):
        self.code = 128 + signum


class Refused(Exception):
    def __init__(self, status, body):
        super().__init__(f"{status} {body.get('code', '')}: {body.get('message', '')}")
        self.status = status
        self.body = body


def answer(error):
    """An error's body; nginx answers in HTML when it cannot reach boat."""
    try:
        return json.load(error)
    except ValueError:
        return {"message": error.reason}


def stop(signum, _frame):
    raise Stopped(signum)


def seconds(text):
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    if text[-1:] in units:
        return int(float(text[:-1]) * units[text[-1]])
    return int(text)


def stamp(at):
    return datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()


class SocketConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCKET)


class SocketHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(SocketConnection, req)


class Boat:
    def __init__(self):
        self.opener = urllib.request.build_opener(SocketHandler())

    def call(self, method, path, body=None, headers=None):
        """One API call; retries what a lost answer or a bad moment on boat's side costs."""
        request = urllib.request.Request(
            BUILDER + path,
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json", "User-Agent": "remote_run/1", **(headers or {})},
        )
        for attempt in range(6):
            try:
                with self.opener.open(request, timeout=60) as reply:
                    return json.load(reply)
            except urllib.error.HTTPError as e:
                if e.code < 500 or e.code == 503 or attempt == 5:
                    raise Refused(e.code, answer(e)) from None
            except (urllib.error.URLError, TimeoutError):
                if attempt == 5:
                    raise
            time.sleep(2**attempt)

    def sandboxes(self, query=""):
        found, cursor = [], ""
        while True:
            page = self.call("GET", f"/sandboxes?limit=200{query}{cursor}")
            found += page["sandboxes"]
            if not page["pageInfo"]["hasMore"]:
                return found
            cursor = "&cursor=" + page["pageInfo"]["nextCursor"]

    def delete(self, sandbox):
        self.call("DELETE", f"/sandboxes/{sandbox}", headers={"X-Ascii-Confirm-Delete": sandbox})


class Run:
    def __init__(self, boat, repository):
        self.boat = boat
        self.id = uuid.uuid4().hex[:8]
        self.sandbox = None
        self.began = time.time()
        STATE.mkdir(parents=True, exist_ok=True)
        (STATE / "logs").mkdir(exist_ok=True)
        now = time.time()
        for old in (STATE / "logs").iterdir():
            if now - old.stat().st_mtime > LOG_DAYS * 86400:
                old.unlink()
        self.name = f"{PREFIX}{re.sub('[^a-z0-9-]', '-', repository.lower())[:40]}-{self.id}"
        self.log_path = STATE / "logs" / f"{time.strftime('%Y%m%d-%H%M%S')}-{repository}-{self.id}.log"
        self.log = self.log_path.open("ab")
        self.keys = tempfile.TemporaryDirectory(prefix="remote_run-")
        self.ssh_config = Path(self.keys.name) / "config"

    def say(self, text):
        line = f"remote_run: [{time.time() - self.began:.0f}s] {text}\n".encode()
        self.log.write(line)
        self.log.flush()
        sys.stderr.buffer.write(line)
        sys.stderr.buffer.flush()

    def reap(self):
        """Removes our sandboxes that outlived their TTL, and returns the account's active ones."""
        active = []
        for s in self.boat.sandboxes():
            state, ours = s["state"], s["name"].startswith(PREFIX)
            expired = s.get("archiveAfter") and stamp(s["archiveAfter"]) < time.time()
            if ours and (expired or state in ("archived", "error")):
                self.say(f"removing {s['id']}, left from an earlier run ({state})")
                self.boat.delete(s["id"])
            elif state not in ("archived", "archiving", "error"):
                active.append(s["id"])
        return active

    def start(self, size, ttl, base, snapshots=False):
        """Claims a sandbox under the ceiling, queueing while it is full.
        The lock makes the count and the create one step across all runs."""
        body = {
            "name": self.name,
            "type": size,
            "ttlSeconds": ttl,
            "noEnv": True,
            "monitoring": False,
            "snapshots": snapshots,
        }
        if base:
            body["from"] = base
        with (STATE / "start.lock").open("w") as lock:
            while True:
                fcntl.flock(lock, fcntl.LOCK_EX)
                try:
                    active = self.reap()
                    wait = 20
                    if len(active) >= CEILING:
                        self.say(f"queued: {len(active)} of {CEILING} sandboxes running")
                    else:
                        try:
                            # A fresh key per attempt: boat holds a refused key for minutes.
                            reply = self.boat.call("POST", "/sandboxes", body, {"Idempotency-Key": str(uuid.uuid4())})
                            self.sandbox = reply["sandbox"]["id"]
                            self.say(f"sandbox {self.sandbox}, {size}, TTL {ttl}s, log {self.log_path}")
                            return
                        except Refused as e:
                            if e.status not in (429, 503):
                                raise
                            wait = e.body.get("retryAfterSeconds", wait)
                            self.say(f"boat refused the start for now ({e.body.get('code')}); retrying")
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                time.sleep(wait)

    def connect(self):
        identity = Path(self.keys.name) / "id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", identity], check=True)
        deadline = time.time() + START_SECONDS
        while True:
            try:
                reply = self.boat.call("POST", f"/sandboxes/{self.sandbox}/sshkey", {"key": identity.with_suffix(".pub").read_text().strip()})
                break
            except Refused as e:
                starting = e.status in (409, 503) or e.body.get("code") == "machine_not_running"
                if not starting or time.time() > deadline:
                    raise
                time.sleep(3)
        self.say("sandbox accepts keys")
        host, port = reply["sshEndpoint"].rsplit(":", 1)
        known = Path(self.keys.name) / "known_hosts"
        known.write_text(f"sandbox {reply['hostKey']}\n")
        self.ssh_config.write_text(
            "Host sandbox\n"
            f"  HostName {host}\n  Port {port}\n  User {USER}\n"
            f"  IdentityFile {identity}\n  IdentitiesOnly yes\n"
            f"  UserKnownHostsFile {known}\n  HostKeyAlias sandbox\n  StrictHostKeyChecking yes\n"
            "  BatchMode yes\n  Compression yes\n  ConnectTimeout 15\n  ServerAliveInterval 30\n  ServerAliveCountMax 4\n"
        )
        while subprocess.run(self.ssh("true"), capture_output=True).returncode:
            if time.time() > deadline:
                raise Failure("the sandbox never answered ssh")
            time.sleep(3)

    def prepare(self, forked):
        """A fork waits out hydration: until then the store crawls, and a job
        spanning its end loses the daemon."""
        if forked:
            self.say("waiting for the fork's disk to hydrate")
            while not self.boat.call("GET", f"/sandboxes/{self.sandbox}")["sandbox"].get("hydrated"):
                time.sleep(10)
            self.say("hydrated")
        self.quietly(self.ssh("bash -s"), input=PREPARE.format(profile=NIX_PROFILE).encode())

    def ssh(self, command):
        return ["ssh", "-F", str(self.ssh_config), "sandbox", command]

    def quietly(self, argv, **options):
        """Runs a step with its output in the log only; its tail shows if it fails."""
        step = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **options)
        self.log.write(step.stdout)
        self.log.flush()
        if step.returncode:
            sys.stderr.buffer.write(b"\n".join(step.stdout.splitlines()[-20:]) + b"\n")
            raise Failure(f"{shlex.join(str(a) for a in argv)[:120]} failed with {step.returncode}")

    def send(self, top, includes):
        """Tracked files as they stand, edits included, plus what was named."""
        self.quietly(self.ssh("rm -rf ~/work && mkdir ~/work"))
        tracked = subprocess.run(["git", "-C", top, "ls-files", "-z", "--cached", "--recurse-submodules"], capture_output=True, check=True).stdout
        names = sorted({n for n in tracked.decode().split("\0") if n and os.path.lexists(os.path.join(top, n))} | set(includes))
        manifest = Path(self.keys.name) / "manifest"
        manifest.write_bytes("\0".join(names).encode() + b"\0")
        packer = subprocess.Popen(["tar", "-C", top, "--null", "-T", manifest, "-cf", "-"], stdout=subprocess.PIPE)
        try:
            self.quietly(self.ssh("tar -xf - -C ~/work"), stdin=packer.stdout)
        finally:
            packer.kill()
        if (Path(top) / "flake.nix").exists():
            # The locked inputs only, private ones too; the source is already
            # there, and a store import crawls while a fork hydrates, so a run
            # whose lock the base already holds should copy nothing.
            flake = subprocess.run(["nix", "flake", "archive", "--no-write-lock-file", "--dry-run", "--json", f"git+file://{top}"], capture_output=True, check=True)
            store = f"ssh-ng://sandbox?remote-program={NIX_PROFILE}/bin/nix-daemon"
            env = {**os.environ, "NIX_SSHOPTS": f"-F {self.ssh_config}"}
            self.quietly(["nix", "copy", "--no-check-sigs", "--to", store, *sorted(inputs(json.loads(flake.stdout)))], env=env)

    def attach(self):
        """Streams the job's log, reconnecting after a dropped connection."""
        sent = 0
        lost = None
        while True:
            follower = subprocess.Popen(self.ssh(ATTACH.format(offset=sent + 1)), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                while chunk := os.read(follower.stdout.fileno(), 65536):
                    sent += len(chunk)
                    lost = None
                    self.log.write(chunk)
                    self.log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                if not follower.wait():
                    return
            finally:
                follower.kill()
            lost = lost or time.time()
            if time.time() - lost > RECONNECT_SECONDS:
                state = self.boat.call("GET", f"/sandboxes/{self.sandbox}")["sandbox"]["state"]
                raise Failure(f"lost the sandbox ({state}); a TTL shorter than the job stops it")
            self.say("connection lost; reconnecting")
            time.sleep(5)

    def job(self, command, prefix=""):
        script = JOB.format(profile=NIX_PROFILE, prefix=shlex.quote(prefix), command=shlex.quote(command))
        self.quietly(self.ssh("cat >~/job.sh; rm -f ~/job.rc ~/job.peak; setsid nohup bash ~/job.sh >~/job.log 2>&1 </dev/null &"), input=script.encode())
        began = time.time()
        self.attach()
        reading = subprocess.run(self.ssh("cat ~/job.rc; cat ~/job.peak 2>/dev/null"), capture_output=True, text=True)
        values = reading.stdout.split()
        if not values:
            raise Failure("the job left no exit code")
        peak = f", peak {int(values[1]) / 1024:.1f} GB" if len(values) > 1 else ""
        self.say(f"exit {values[0]} after {time.time() - began:.0f}s{peak}")
        return int(values[0])

    def fetch(self, patterns, prefix):
        """Named artifacts land at the same relative path, so a fetched APK sits
        where a local build would have put it."""
        remote = f"cd ~/work/{shlex.quote(prefix)} && shopt -s nullglob globstar && set -- {' '.join(patterns)}; (($#)) && tar -chf - -- \"$@\""
        packer = subprocess.Popen(self.ssh(f"bash -c {shlex.quote(remote)}"), stdout=subprocess.PIPE)
        try:
            unpacked = subprocess.run(["tar", "-xf", "-", "--no-same-owner"], stdin=packer.stdout, capture_output=True)
        finally:
            packer.stdout.close()
        if packer.wait() or unpacked.returncode:
            self.say(f"fetching {' '.join(patterns)} failed or matched nothing")

    def report_cost(self):
        spent = self.boat.call("GET", f"/sandboxes/{self.sandbox}/usage")
        self.say(f"cost ${spent['dollars']:.3f}, {spent['seconds'] / 3600:.2f} included hours")

    def destroy(self):
        """Deletes by name, so a create whose answer never came is caught too.
        If this cannot reach boat, the TTL ends the sandbox."""
        for attempt in range(4):
            try:
                for s in self.boat.sandboxes(f"&namePrefix={self.name}"):
                    self.boat.delete(s["id"])
                    self.say(f"deleted {s['id']}")
                return
            except (OSError, Refused) as e:
                self.say(f"deleting failed ({e}); attempt {attempt + 1}")
                time.sleep(5)
        self.say("could not delete the sandbox; its TTL will end it")

    def close(self):
        self.keys.cleanup()
        self.log.close()


def inputs(flake):
    """The store paths of a `nix flake archive --json` tree, itself left out."""
    found = set()
    for child in flake.get("inputs", {}).values():
        found |= {child["path"]} | inputs(child)
    return found


def worktree():
    git = subprocess.run(["git", "rev-parse", "--show-toplevel", "--show-prefix"], capture_output=True, text=True)
    if git.returncode:
        raise Failure("run this from a git worktree")
    top, prefix = (git.stdout.split("\n") + [""])[:2]
    return top, prefix


def run_command(run, args, command):
    top, prefix = worktree()
    includes = [os.path.relpath(os.path.join(os.getcwd(), p), top) for p in args.include]
    run.start(args.size, seconds(args.ttl), args.base)
    run.connect()
    run.prepare(bool(args.base))
    run.send(top, includes)
    run.say(f"source sent; running: {command}")
    code = run.job(command, prefix)
    if args.fetch:
        run.fetch(args.fetch, prefix)
    run.report_cost()
    return code


def refresh_base(run, args):
    """Rebuilds the base from a bare sandbox rather than growing the old one: a
    flake update changes most of the store, the disk has no room for two
    generations, and the same path recovers a lost base. The base in use stays
    in place until the new one has passed."""
    run.start(args.size, seconds(REFRESH_TTL), None, snapshots=True)
    run.connect()
    run.prepare(False)
    run.quietly(run.ssh("bash -s"), input=BOOTSTRAP.encode())
    for seed in args.seeds or SEEDS:
        top = os.path.expanduser(seed)
        run.send(top, [])
        steps = ("nix flake check --keep-going -L",) + SEED_SHELLS.get(Path(top).name, ())
        run.say(f"seeding from {top}")
        code = run.job(" && ".join(steps))
        if code:
            raise Failure(f"{top} did not pass, so {args.base} stays as it was")
    run.quietly(run.ssh("rm -rf ~/work ~/job.* ~/nix-install.log ~/.android ~/.gradle ~/.ssh/authorized_keys; sed -i /ASCII_TOKEN/d ~/.bashrc"))
    run.boat.call("POST", "/saved-snapshots", {"sandboxId": run.sandbox, "name": args.base})
    while True:
        saved = run.boat.call("GET", f"/saved-snapshots/{args.base}")["snapshot"]
        if saved["status"] == "ready":
            run.say(f"{args.base} saved, {saved.get('sizeBytes', 0) / 2**30:.0f} GB")
            run.report_cost()
            return 0
        if saved["status"] == "failed":
            raise Failure(f"saving {args.base} failed: {saved.get('error')}")
        time.sleep(15)


def main():
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        split = argv.index("--")
        argv, command = argv[:split], argv[split + 1:]
    parser = argparse.ArgumentParser(prog="remote_run", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", nargs="?", choices=("check", "refresh-base"))
    parser.add_argument("seeds", nargs="*", help="refresh-base: worktrees to seed from")
    parser.add_argument("--size", default=SIZE, choices=("small", "default", "large", "xlarge"))
    parser.add_argument("--ttl", default=TTL, help="stop the sandbox after this long whatever happens: 90m, 3h")
    parser.add_argument("--fetch", action="append", default=[], metavar="PATH", help="copy this back afterwards; globs allowed; repeatable")
    parser.add_argument("--include", action="append", default=[], metavar="PATH", help="send this untracked path too; repeatable")
    parser.add_argument("--base", default=BASE, help="saved snapshot to start from, or to refresh")
    args = parser.parse_args(argv)
    if not command and args.action is None:
        parser.error("name a command after --, or use check or refresh-base")
    if args.action == "check":
        command = ["nix", "flake", "check", "--keep-going", "-L"]
    # One word is shell text; several are an exact argument list.
    text = command[0] if len(command) == 1 else shlex.join(command)

    for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(caught, stop)
    run = None
    code = FAILED
    try:
        repository = Path(worktree()[0]).name if args.action != "refresh-base" else "base"
        run = Run(Boat(), repository)
        code = refresh_base(run, args) if args.action == "refresh-base" else run_command(run, args, text)
    except Stopped as s:
        code = s.code
    except Failure as e:
        print(f"remote_run: {e}", file=sys.stderr)
    except Exception:
        traceback.print_exc()
    finally:
        for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(caught, signal.SIG_IGN)
        if run:
            run.destroy()
            run.close()
    sys.exit(code)


main()
