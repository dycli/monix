"""deploy_libri.sh moves the one build link the seat's Libri and Suki run
only once both are quiet, and puts both back if either doesn't answer.

The script runs in a scratch repository with nix, systemctl, curl and sleep
stood in for, so each way a deploy can end is played out: a failed build, a
build one instance doesn't answer on, a good one, and work still running at
the quiet wait's ceiling, each way its switch is set. Throughout the wait the
link must still name the old build, since the units restart from it on their
own if they die.
Usage: check_deploy.py AWAIT_QUIET_SH DEPLOY_LIBRI_SH
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WAIT = Path(sys.argv[1])
LIBRI = Path(sys.argv[2])
failures = []


def check(what, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + what + (f": {detail}" if not ok and detail else ""))
    if not ok:
        failures.append(what)


STUBS = {
    # The build answers as BUILD says, and a good one leaves its out-link,
    # noted as a GC root. A store path builds to itself, the flake to NEW.
    "nix": """
[ "$BUILD" = ok ] || exit 1
target=${NEW:-/nix/store/new}
case "$2" in /*) target=$2 ;; esac
while [ $# -gt 0 ]; do [ "$1" = -o ] && ln -sfn "$target" "$2" && echo "$2" >> "$STUBS/roots"; shift; done
exit 0
""",
    # Each restart moves the unit's start time on, and is noted.
    "systemctl": """
if [ "$1" = show ]; then cat "$STUBS/started"; exit 0; fi
if [ "$1" = restart ]; then shift; echo "$*" >> "$STUBS/restarts"
  case " $* " in *" $FAIL_UNIT "*) exit 1 ;; esac
  echo $(( $(cat "$STUBS/started") + 1 )) > "$STUBS/started"; fi
""",
    # /api/task is quiet; /api/host answers as HEALTH says, or on Suki's
    # port as SUKI_HEALTH says. Each look at the task notes where the
    # units' link points while the deploy waits.
    "curl": """
case "$*" in
  *api/task*) readlink "$LINK_UNDER_TEST" >> "$STUBS/link_while_waiting"
              if [ -n "$BUSY" ]; then echo "{\\"typing\\":false,\\"quiet\\":false,\\"busy\\":${BUSY_LIST:-[\\"the main turn\\",\\"worker kit-1\\",\\"Temp\\"]}}"
              else echo '{"typing":false,"quiet":true,"busy":[]}'; fi ;;
  *8952/api/host*) printf '%s' "${SUKI_HEALTH:-$HEALTH}" ;;
  *) printf '%s' "$HEALTH" ;;
esac
""",
    "sleep": "true",
}


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def scratch():
    root = Path(tempfile.mkdtemp(prefix="deploy-"))
    repo, stubs = root / "repo", root / "stubs"
    repo.mkdir()
    stubs.mkdir()
    for name, body in STUBS.items():
        (stubs / name).write_text("#!/bin/sh\n" + body + "\n")
        (stubs / name).chmod(0o755)
    (stubs / "started").write_text("1")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "check@libri")
    git(repo, "config", "user.name", "check")
    (repo / "flake.nix").write_text("{}\n")
    shutil.copy(WAIT, stubs / "await_quiet.sh")
    shutil.copy(LIBRI, stubs / "deploy_libri.sh")
    os.symlink("/nix/store/previous", stubs / "link")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "first")
    return root, repo, stubs


def deploy(repo, stubs, build, health, **more):
    link = str(stubs / "link")
    env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", STUBS=str(stubs), BUILD=build, HEALTH=health,
               DEPLOY_LIBRI_LOG=str(stubs / "log"), DEPLOY_LIBRI_LINK=link, LINK_UNDER_TEST=link,
               **more)
    return subprocess.run(["sh", str(stubs / "deploy_libri.sh"), str(repo)], env=env).returncode


def links(stubs):
    """Where the link ends, whether a staged build is left, and whether the
    link named only the old build while the deploy waited."""
    waited = (stubs / "link_while_waiting").read_text().split() if (stubs / "link_while_waiting").exists() else []
    return os.readlink(stubs / "link"), (stubs / "link.next").is_symlink(), set(waited) <= {"/nix/store/previous"}


for case, build, health, suki, moves in (
    ("a failed build", "fail", "200", None, False),
    ("a build Libri doesn't answer on", "ok", "500", None, False),
    ("a build Suki doesn't answer on", "ok", "200", "500", False),
    ("a build both answer on", "ok", "200", None, True),
):
    root, repo, stubs = scratch()
    code = deploy(repo, stubs, build, health, **({"SUKI_HEALTH": suki} if suki else {}))
    link, staged, old_while_waiting = links(stubs)
    check(f"{case} ends {'well' if moves else 'badly'}", (code == 0) == moves, code)
    check(f"{case} {'moves' if moves else 'leaves'} the link",
          link == ("/nix/store/new" if moves else "/nix/store/previous"), link)
    check(f"{case} leaves no staged build", not staged)
    check(f"{case} keeps the old build while it waits", old_while_waiting)
    shutil.rmtree(root)

# Busy past the ceiling: the default restarts anyway, "stop" stops without
# restarting; either way the log names what is at work, once, not each second.
for case, at_limit, moves in (("the default", None, True), ("stop", "stop", False)):
    root, repo, stubs = scratch()
    more = dict(BUSY="1", DEPLOY_QUIET_LIMIT="1") | ({"DEPLOY_AT_LIMIT": at_limit} if at_limit else {})
    code = deploy(repo, stubs, "ok", "200", **more)
    log = (stubs / "log").read_text()
    restarted = (stubs / "started").read_text().strip() != "1"
    what = f"busy past the ceiling with {case}"
    check(f"{what} {'deploys' if moves else 'stops'}",
          (code == 0) == moves and restarted == moves, f"code {code}, restarted {restarted}\n{log}")
    check(f"{what} names what is at work", log.count("the main turn, Temp") >= 1, log)
    link, staged, old_while_waiting = links(stubs)
    check(f"{what} {'switches' if moves else 'keeps'} the link",
          link == ("/nix/store/new" if moves else "/nix/store/previous"), link)
    check(f"{what} leaves no staged build", not staged)
    check(f"{what} keeps the old build while it waits", old_while_waiting)
    shutil.rmtree(root)

# Workers don't hold a deploy: with only workers at work it goes at once,
# even with the ceiling set to stop; the main turn or Temp still holds it.
for case, busy, moves in (("only workers", '["worker kit-1","worker kitty-1"]', True),
                          ("the main turn", '["the main turn","worker kit-1"]', False),
                          ("Temp", '["Temp"]', False)):
    root, repo, stubs = scratch()
    code = deploy(repo, stubs, "ok", "200", BUSY="1", BUSY_LIST=busy,
                  DEPLOY_QUIET_LIMIT="1", DEPLOY_AT_LIMIT="stop")
    log = (stubs / "log").read_text()
    check(f"a deploy with {case} at work {'goes' if moves else 'waits'}", (code == 0) == moves, log)
    check(f"a deploy with {case} at work names no worker", "worker kit" not in log, log)
    shutil.rmtree(root)

# A good deploy restarts both instances, each after the hippos.
root, repo, stubs = scratch()
deploy(repo, stubs, "ok", "200")
restarts = (stubs / "restarts").read_text().split()
check("a good deploy restarts the seat's Libri and Suki", restarts[-2:] == ["libri.service", "suki.service"], restarts)
shutil.rmtree(root)

# Every move of the units' link goes through nix, so the link is a GC root
# even on a host whose link the old script made with ln.
for case, health, to in (("a good build", "200", "/nix/store/new"), ("a build that doesn't answer", "500",
                                                                     "/nix/store/previous")):
    root, repo, stubs = scratch()
    deploy(repo, stubs, "ok", health)
    roots = (stubs / "roots").read_text().split() if (stubs / "roots").exists() else []
    link = os.readlink(stubs / "link")
    check(f"{case} leaves the link a GC root", link == to and str(stubs / "link") in roots,
          f"link {link}, roots {roots}")
    shutil.rmtree(root)


def build(stubs, name, hippo):
    """A build whose bin/hippo resolves to a hippo binary shared by name, as
    nix shares an unchanged package between builds."""
    (stubs / "hippos").mkdir(exist_ok=True)
    (stubs / "hippos" / hippo).write_text("")
    (stubs / name / "bin").mkdir(parents=True)
    os.symlink(stubs / "hippos" / hippo, stubs / name / "bin" / "hippo")
    return str(stubs / name)


def hippo_restarted(stubs):
    restarts = (stubs / "restarts").read_text().split() if (stubs / "restarts").exists() else []
    (stubs / "restarts").unlink(missing_ok=True)
    return "hippo.service" in restarts


# deploy_libri.sh restarts the seat's hippo when the hippo it last started
# differs from the new one, not when the link's old and new targets differ: a deploy
# killed after moving the link leaves those the same.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1"), build(stubs, "new", "h2")
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
deploy(repo, stubs, "ok", "200", NEW=new)
check("deploy_libri.sh restarts hippo on a new hippo", hippo_restarted(stubs))
(stubs / "link.hippo").write_text(str(stubs / "hippos" / "h1") + "\n")  # killed before the restart
deploy(repo, stubs, "ok", "200", NEW=new)
check("deploy_libri.sh rerun after a kill between link and restart restarts hippo", hippo_restarted(stubs))
deploy(repo, stubs, "ok", "200", NEW=new)
check("deploy_libri.sh leaves hippo be when it already runs the new hippo", not hippo_restarted(stubs))
same = build(stubs, "same", "h2")
deploy(repo, stubs, "ok", "200", NEW=same)
check("deploy_libri.sh leaves hippo be when only Libri changed", not hippo_restarted(stubs))
shutil.rmtree(root)

# deploy_libri.sh's rollback restarts the seat's hippo, records its binary
# only if that restart succeeded, then restarts both instances, as the
# deploy itself does.
# A failed restart leaves the record as it was (h0 here).
for fail, recorded in (("", "h1"), ("hippo.service", "h0")):
    root, repo, stubs = scratch()
    old, new = build(stubs, "old", "h1"), build(stubs, "new", "h2")
    (stubs / "link").unlink()
    os.symlink(old, stubs / "link")
    (stubs / "link.hippo").write_text(str(stubs / "hippos" / "h0") + "\n")
    deploy(repo, stubs, "ok", "500", NEW=new, FAIL_UNIT=fail)
    restarts = (stubs / "restarts").read_text().splitlines()
    ran = Path((stubs / "link.hippo").read_text().strip()).name
    case = "a failed hippo restart" if fail else "a hippo restart"
    check(f"deploy_libri.sh rollback after {case} records {recorded} and restarts both",
          restarts[-3:] == ["hippo.service", "libri.service", "suki.service"]
          and ran == recorded,
          f"restarts {restarts}, recorded {ran}")
    shutil.rmtree(root)

if failures:
    sys.exit(f"{len(failures)} failed")
print("all checks passed")
