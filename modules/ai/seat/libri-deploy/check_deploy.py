"""Exercise deployment and rollback with stubbed nix, systemctl, curl and sleep.

Usage: check_deploy.py DEPLOY_LIBRI_SH
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LIBRI = Path(sys.argv[1])
failures = []


def check(what, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + what + (f": {detail}" if not ok and detail else ""))
    if not ok:
        failures.append(what)


STUBS = {
    # The build answers as BUILD says, and a good one leaves its out-link,
    # noted as a GC root. A store path builds to itself, `.#default` builds
    # to NEW, and `.#<addon>` builds to `$ADDON_NEW_DIR/<addon>` (or a
    # synthetic store path) unless FAIL_ADDON names that add-on.
    "nix": """
[ "$BUILD" = ok ] || exit 1
target=${NEW:-/nix/store/new}
case "$2" in
  /*) target=$2 ;;
  .#default) ;;
  .#*)
    addon=${2#.#}
    [ "$addon" != "$FAIL_ADDON" ] || exit 1
    if [ -n "$ADDON_NEW_DIR" ] && [ -e "$ADDON_NEW_DIR/$addon" ]; then
      target=$(readlink "$ADDON_NEW_DIR/$addon" 2>/dev/null || echo "$ADDON_NEW_DIR/$addon")
    else
      target="/nix/store/new-$addon"
    fi
    ;;
esac
while [ $# -gt 0 ]; do [ "$1" = -o ] && ln -sfn "$target" "$2" && echo "$2" >> "$STUBS/roots"; shift; done
exit 0
""",
    # Record service operations and simulate restart failures.
    "systemctl": """
if [ "$1" = is-active ]; then case " $ACTIVE " in *" $3 "*) exit 0 ;; esac; exit 3; fi
if [ "$1" = stop ]; then echo "$2" >> "$STUBS/stops"; exit 0; fi
if [ "$1" = restart ]; then shift; echo "$*" >> "$STUBS/restarts"
  case "$1" in
    *-core.service)
      readlink "$LINK_UNDER_TEST" >> "$STUBS/core_builds"
      [ "$(readlink "$LINK_UNDER_TEST")" != "$FAIL_CORE_BUILD" ] || exit 1
      ;;
  esac
  case " $* " in *" $FAIL_UNIT "*) exit 1 ;; esac
fi
""",
    # Record requests so the successful deploy checks every health endpoint.
    "curl": """
echo "$*" >> "$STUBS/requests"
case "$*" in
  *8951/api/host) printf '%s' "$HEALTH" ;;
  *8952/api/host) printf '%s' "${SUKI_HEALTH:-$HEALTH}" ;;
  *8953/) printf '%s' "${GATEWAY_HEALTH:-$HEALTH}" ;;
  *8954/) printf '%s' "${SUKI_GATEWAY_HEALTH:-$HEALTH}" ;;
  *) exit 1 ;;
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
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "check@libri")
    git(repo, "config", "user.name", "check")
    (repo / "flake.nix").write_text("{}\n")
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


for case, build, health, suki, moves in (
    ("a failed build", "fail", "200", None, False),
    ("a build Libri doesn't answer on", "ok", "500", None, False),
    ("a build Suki doesn't answer on", "ok", "200", "500", False),
    ("a build both answer on", "ok", "200", None, True),
):
    root, repo, stubs = scratch()
    code = deploy(repo, stubs, build, health, **({"SUKI_HEALTH": suki} if suki else {}))
    link = os.readlink(stubs / "link")
    staged = (stubs / "link.next").is_symlink()
    check(f"{case} ends {'well' if moves else 'badly'}", (code == 0) == moves, code)
    check(f"{case} {'moves' if moves else 'leaves'} the link",
          link == ("/nix/store/new" if moves else "/nix/store/previous"), link)
    check(f"{case} leaves no staged build", not staged)
    shutil.rmtree(root)

# A good deploy restarts both instances, each after the hippos.
root, repo, stubs = scratch()
deploy(repo, stubs, "ok", "200")
restarts = (stubs / "restarts").read_text().split()
check("a good deploy restarts the seat's Libri and Suki", restarts[-2:] == ["libri.service", "suki.service"], restarts)
requests = [line.split()[-1] for line in (stubs / "requests").read_text().splitlines()]
check("a good deploy requests only the two health endpoints", requests == [
    "http://127.0.0.1:8951/api/host",
    "http://127.0.0.1:8952/api/host",
], requests)
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


def build(stubs, name, hippo, *, core=False):
    """A build whose bin/hippo resolves to a hippo binary shared by name, as
    nix shares an unchanged package between builds."""
    (stubs / "hippos").mkdir(exist_ok=True)
    (stubs / "hippos" / hippo).write_text("")
    (stubs / name / "bin").mkdir(parents=True)
    os.symlink(stubs / "hippos" / hippo, stubs / name / "bin" / "hippo")
    if core:
        binary = stubs / name / "bin" / "libri-core"
        binary.touch()
        binary.chmod(0o755)
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

# The trial starts with the first release that carries the core. A failed
# start rolls the shared link back before either assistant is restarted.
for old_core, new_core, fails, core_builds, stops in (
    (False, True, False, ["new"], []),
    (False, True, True, ["new"], ["libri-core.service"]),
    (True, True, True, ["new", "old"], []),
    (True, False, False, [], []),
):
    root, repo, stubs = scratch()
    old = build(stubs, "old", "h1", core=old_core)
    new = build(stubs, "new", "h1", core=new_core)
    (stubs / "link").unlink()
    os.symlink(old, stubs / "link")
    (stubs / "link.hippo").write_text(str(stubs / "hippos" / "h1") + "\n")
    result = deploy(repo, stubs, "ok", "200", NEW=new, FAIL_CORE_BUILD=new if fails else "")
    ran = (stubs / "core_builds").read_text().splitlines() if (stubs / "core_builds").exists() else []
    stopped = (stubs / "stops").read_text().splitlines() if (stubs / "stops").exists() else []
    restarted = (stubs / "restarts").read_text().splitlines() if (stubs / "restarts").exists() else []
    expected_restarts = ["libri-core.service"] * len(core_builds)
    if new_core:
        expected_restarts += ["libri.service", "suki.service"]
    succeeds = new_core and not fails
    check(f"shared build with core before={old_core} after={new_core} start fails={fails}",
          (result == 0) == succeeds and os.readlink(stubs / "link") == (new if succeeds else old)
          and [Path(path).name for path in ran] == core_builds
          and stopped == stops and restarted == expected_restarts,
          f"result {result}, core builds {ran}, stops {stopped}, restarts {restarted}")
    shutil.rmtree(root)

# A running gateway restarts on the core's build right after the core, on
# a good deploy and again on the rollback; one not running stays off.
for case, health, cores in (("a good deploy", "200", 1), ("a rolled-back deploy", "500", 2)):
    for active in (True, False):
        root, repo, stubs = scratch()
        old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h1", core=True)
        (stubs / "link").unlink()
        os.symlink(old, stubs / "link")
        deploy(repo, stubs, "ok", health, NEW=new, **({"ACTIVE": "libri-gateway.service"} if active else {}))
        restarts = (stubs / "restarts").read_text().split()
        after = [restarts[i + 1] if i + 1 < len(restarts) else None
                 for i, unit in enumerate(restarts) if unit == "libri-core.service"]
        if active:
            check(f"{case} restarts a running gateway after the core",
                  after == ["libri-gateway.service"] * cores and restarts.count("libri-gateway.service") == cores,
                  restarts)
        else:
            check(f"{case} leaves a gateway that isn't running", "libri-gateway.service" not in restarts, restarts)
        shutil.rmtree(root)

def addon_build(stubs, name, label, binary_id):
    """An add-on build whose bin/libri-<name> resolves to a shared binary by
    binary_id, as nix shares an unchanged add-on binary between builds."""
    (stubs / "addon-bins").mkdir(exist_ok=True)
    target = stubs / "addon-bins" / f"{name}-{binary_id}"
    target.write_text("")
    target.chmod(0o755)
    out = stubs / f"addon-{name}-{label}"
    (out / "bin").mkdir(parents=True)
    os.symlink(target, out / "bin" / f"libri-{name}")
    return str(out), str(target)


# A failed add-on build cleans up all staged links and leaves live links untouched.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h1", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, _ = addon_build(stubs, "boards", "old", "b1")
old_files, _ = addon_build(stubs, "files", "old", "f1")
os.symlink(old_boards, addons_dir / "boards")
os.symlink(old_files, addons_dir / "files")
code = deploy(
    repo, stubs, "ok", "200", NEW=new,
    DEPLOY_LIBRI_ADDONS="boards files",
    DEPLOY_LIBRI_SERVED_ADDONS="boards files",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    FAIL_ADDON="files",
)
check("a failed addon build aborts and leaves all live links untouched",
      code != 0
      and os.readlink(stubs / "link") == old
      and os.readlink(addons_dir / "boards") == old_boards
      and os.readlink(addons_dir / "files") == old_files
      and not (stubs / "link.next").is_symlink()
      and not (addons_dir / "boards.next").is_symlink()
      and not (addons_dir / "files.next").is_symlink()
      and not (stubs / "restarts").exists(),
      f"code {code}, link {os.readlink(stubs / 'link')}")
shutil.rmtree(root)

# A good deploy swaps each add-on GC-root link, restarts only served add-ons
# whose binary changed (before the gateway), and handles kill-between-link-and-restart.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h1", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
(stubs / "link.hippo").write_text(str(stubs / "hippos" / "h1") + "\n")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, b1 = addon_build(stubs, "boards", "old", "b1")
new_boards, b2 = addon_build(stubs, "boards", "new", "b2")
old_files, f1 = addon_build(stubs, "files", "old", "f1")
new_files, _ = addon_build(stubs, "files", "new", "f1")
old_ui, _ = addon_build(stubs, "ui", "old", "u1")
new_ui, _ = addon_build(stubs, "ui", "new", "u2")
os.symlink(old_boards, addons_dir / "boards")
os.symlink(old_files, addons_dir / "files")
os.symlink(old_ui, addons_dir / "ui")
(addons_dir / ".boards.ran").write_text(b1 + "\n")
(addons_dir / ".files.ran").write_text(f1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_boards, new_dir / "boards")
os.symlink(new_files, new_dir / "files")
os.symlink(new_ui, new_dir / "ui")
code = deploy(
    repo, stubs, "ok", "200", NEW=new, ACTIVE="libri-gateway.service",
    DEPLOY_LIBRI_ADDONS="boards files ui",
    DEPLOY_LIBRI_SERVED_ADDONS="boards files",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
roots = (stubs / "roots").read_text().splitlines()
check("a good deploy updates all addon links as GC roots and restarts only changed served addons before gateway",
      code == 0
      and os.readlink(addons_dir / "boards") == new_boards
      and os.readlink(addons_dir / "files") == new_files
      and os.readlink(addons_dir / "ui") == new_ui
      and all(str(addons_dir / a) in roots for a in ("boards", "files", "ui"))
      and not any((addons_dir / f"{a}.next").is_symlink() for a in ("boards", "files", "ui"))
      and restarts == ["libri-core.service", "libri-addon-boards.service", "libri-gateway.service", "libri.service", "suki.service"]
      and (addons_dir / ".boards.ran").read_text().strip() == b2,
      f"code {code}, restarts {restarts}")
(stubs / "restarts").unlink()
# Second deploy with same binaries restarts no add-ons.
deploy(
    repo, stubs, "ok", "200", NEW=new, ACTIVE="libri-gateway.service",
    DEPLOY_LIBRI_ADDONS="boards files ui",
    DEPLOY_LIBRI_SERVED_ADDONS="boards files",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("a repeat deploy with unchanged addon binaries restarts no served addons",
      "libri-addon-boards.service" not in restarts and "libri-addon-files.service" not in restarts,
      restarts)
(stubs / "restarts").unlink()
# Simulate kill between moving link and restarting: .boards.ran still holds b1.
(addons_dir / ".boards.ran").write_text(b1 + "\n")
deploy(
    repo, stubs, "ok", "200", NEW=new,
    DEPLOY_LIBRI_ADDONS="boards files ui",
    DEPLOY_LIBRI_SERVED_ADDONS="boards files",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("a rerun after a kill between addon link move and restart restarts the addon",
      "libri-addon-boards.service" in restarts and "libri-addon-files.service" not in restarts
      and (addons_dir / ".boards.ran").read_text().strip() == b2,
      restarts)
shutil.rmtree(root)

# Rollback on health failure restores previous addon links, removes newly added
# links, and restarts only served add-ons that were moved.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h1", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
(stubs / "link.hippo").write_text(str(stubs / "hippos" / "h1") + "\n")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, b1 = addon_build(stubs, "boards", "old", "b1")
new_boards, _ = addon_build(stubs, "boards", "new", "b2")
old_files, f1 = addon_build(stubs, "files", "old", "f1")
new_files, _ = addon_build(stubs, "files", "new", "f1")
new_search, _ = addon_build(stubs, "search", "new", "s1")
os.symlink(old_boards, addons_dir / "boards")
os.symlink(old_files, addons_dir / "files")
(addons_dir / ".boards.ran").write_text(b1 + "\n")
(addons_dir / ".files.ran").write_text(f1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_boards, new_dir / "boards")
os.symlink(new_files, new_dir / "files")
os.symlink(new_search, new_dir / "search")
code = deploy(
    repo, stubs, "ok", "500", NEW=new,
    DEPLOY_LIBRI_ADDONS="boards files search",
    DEPLOY_LIBRI_SERVED_ADDONS="boards files",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("rollback on health failure restores addon links and restarts only changed served addons",
      code != 0
      and os.readlink(addons_dir / "boards") == old_boards
      and os.readlink(addons_dir / "files") == old_files
      and not (addons_dir / "search").is_symlink()
      and restarts.count("libri-addon-boards.service") == 2
      and "libri-addon-files.service" not in restarts
      and (addons_dir / ".boards.ran").read_text().strip() == b1,
      f"code {code}, restarts {restarts}")
shutil.rmtree(root)

# Rollback when libri-core fails to start restores addon links without
# needlessly restarting served add-ons that were never switched.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h1", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
(stubs / "link.hippo").write_text(str(stubs / "hippos" / "h1") + "\n")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, b1 = addon_build(stubs, "boards", "old", "b1")
new_boards, _ = addon_build(stubs, "boards", "new", "b2")
os.symlink(old_boards, addons_dir / "boards")
(addons_dir / ".boards.ran").write_text(b1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_boards, new_dir / "boards")
code = deploy(
    repo, stubs, "ok", "200", NEW=new, FAIL_CORE_BUILD=new,
    DEPLOY_LIBRI_ADDONS="boards",
    DEPLOY_LIBRI_SERVED_ADDONS="boards",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("rollback on libri-core failure restores addon links without restarting untouched served addons",
      code != 0
      and os.readlink(addons_dir / "boards") == old_boards
      and "libri-addon-boards.service" not in restarts
      and (addons_dir / ".boards.ran").read_text().strip() == b1,
      f"code {code}, restarts {restarts}")
shutil.rmtree(root)

# A failed served add-on restart leaves its .ran record unchanged.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h1", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
(stubs / "link.hippo").write_text(str(stubs / "hippos" / "h1") + "\n")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, b1 = addon_build(stubs, "boards", "old", "b1")
new_boards, _ = addon_build(stubs, "boards", "new", "b2")
os.symlink(old_boards, addons_dir / "boards")
(addons_dir / ".boards.ran").write_text(b1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_boards, new_dir / "boards")
code = deploy(
    repo, stubs, "ok", "200", NEW=new, FAIL_UNIT="libri-addon-boards.service",
    DEPLOY_LIBRI_ADDONS="boards",
    DEPLOY_LIBRI_SERVED_ADDONS="boards",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
check("a failed served addon restart leaves its .ran record unchanged",
      code == 0 and (addons_dir / ".boards.ran").read_text().strip() == b1,
      f"code {code}, ran {(addons_dir / '.boards.ran').read_text().strip()}")
shutil.rmtree(root)

# Stage 2-only mode: legacy libri and hippo are retired (DEPLOY_LIBRI_INSTANCES="suki:8952",
# DEPLOY_LIBRI_HIPPOS="", DEPLOY_LIBRI_GATEWAY_PORT="8953"), with a2a among served add-ons.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h2", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, b1 = addon_build(stubs, "boards", "old", "b1")
new_boards, _ = addon_build(stubs, "boards", "new", "b1")
old_a2a, a1 = addon_build(stubs, "a2a", "old", "a1")
new_a2a, a2 = addon_build(stubs, "a2a", "new", "a2")
os.symlink(old_boards, addons_dir / "boards")
os.symlink(old_a2a, addons_dir / "a2a")
(addons_dir / ".boards.ran").write_text(b1 + "\n")
(addons_dir / ".a2a.ran").write_text(a1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_boards, new_dir / "boards")
os.symlink(new_a2a, new_dir / "a2a")
code = deploy(
    repo, stubs, "ok", "200", NEW=new, ACTIVE="libri-gateway.service",
    DEPLOY_LIBRI_INSTANCES="suki:8952",
    DEPLOY_LIBRI_HIPPOS="",
    DEPLOY_LIBRI_GATEWAY_PORT="8953",
    DEPLOY_LIBRI_ADDONS="boards a2a",
    DEPLOY_LIBRI_SERVED_ADDONS="boards a2a",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
requests = [line.split()[-1] for line in (stubs / "requests").read_text().splitlines()]
check("Stage 2-only deploy restarts core, changed a2a addon, gateway, and Suki without legacy libri or hippo",
      code == 0
      and restarts == ["libri-core.service", "libri-addon-a2a.service", "libri-gateway.service", "suki.service"]
      and requests == ["http://127.0.0.1:8953/", "http://127.0.0.1:8952/api/host"]
      and (addons_dir / ".a2a.ran").read_text().strip() == a2,
      f"code {code}, restarts {restarts}, requests {requests}")
(stubs / "restarts").unlink()
(stubs / "requests").unlink()
# Repeat deploy with unchanged a2a binary leaves libri-addon-a2a alone.
code = deploy(
    repo, stubs, "ok", "200", NEW=new, ACTIVE="libri-gateway.service",
    DEPLOY_LIBRI_INSTANCES="suki:8952",
    DEPLOY_LIBRI_HIPPOS="",
    DEPLOY_LIBRI_GATEWAY_PORT="8953",
    DEPLOY_LIBRI_ADDONS="boards a2a",
    DEPLOY_LIBRI_SERVED_ADDONS="boards a2a",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("Stage 2-only repeat deploy with unchanged a2a skips libri-addon-a2a",
      code == 0 and restarts == ["libri-core.service", "libri-gateway.service", "suki.service"],
      f"code {code}, restarts {restarts}")
shutil.rmtree(root)

# Stage 2-only gateway health failure rolls back link, a2a add-on, gateway, and Suki.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h2", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_a2a, a1 = addon_build(stubs, "a2a", "old", "a1")
new_a2a, _ = addon_build(stubs, "a2a", "new", "a2")
os.symlink(old_a2a, addons_dir / "a2a")
(addons_dir / ".a2a.ran").write_text(a1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_a2a, new_dir / "a2a")
code = deploy(
    repo, stubs, "ok", "200", NEW=new, ACTIVE="libri-gateway.service",
    GATEWAY_HEALTH="500",
    DEPLOY_LIBRI_INSTANCES="suki:8952",
    DEPLOY_LIBRI_HIPPOS="",
    DEPLOY_LIBRI_GATEWAY_PORT="8953",
    DEPLOY_LIBRI_ADDONS="a2a",
    DEPLOY_LIBRI_SERVED_ADDONS="a2a",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("Stage 2-only gateway health failure rolls back core, a2a, gateway, and Suki without legacy units",
      code != 0
      and os.readlink(stubs / "link") == old
      and os.readlink(addons_dir / "a2a") == old_a2a
      and restarts == [
          "libri-core.service", "libri-addon-a2a.service", "libri-gateway.service", "suki.service",
          "libri-core.service", "libri-addon-a2a.service", "libri-gateway.service", "suki.service",
      ]
      and (addons_dir / ".a2a.ran").read_text().strip() == a1,
      f"code {code}, restarts {restarts}")
shutil.rmtree(root)

# Multi-assistant Stage 2 deploy: two cores (libri-core, suki-core), shared
# connect + computer add-on links, per-assistant unit:addon served add-ons,
# and two active gateways (libri-gateway:8953, suki-gateway:8954).
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h2", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, b1 = addon_build(stubs, "boards", "old", "b1")
new_boards, b2 = addon_build(stubs, "boards", "new", "b2")
old_connect, _ = addon_build(stubs, "connect", "old", "c1")
new_connect, _ = addon_build(stubs, "connect", "new", "c2")
old_computer, _ = addon_build(stubs, "computer", "old", "m1")
new_computer, _ = addon_build(stubs, "computer", "new", "m2")
os.symlink(old_boards, addons_dir / "boards")
os.symlink(old_connect, addons_dir / "connect")
os.symlink(old_computer, addons_dir / "computer")
(addons_dir / ".boards.ran").write_text(b1 + "\n")
(addons_dir / ".suki-addon-boards.ran").write_text(b1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_boards, new_dir / "boards")
os.symlink(new_connect, new_dir / "connect")
os.symlink(new_computer, new_dir / "computer")
code = deploy(
    repo, stubs, "ok", "200", NEW=new,
    ACTIVE="libri-gateway.service suki-gateway.service",
    DEPLOY_LIBRI_CORES="libri-core suki-core",
    DEPLOY_LIBRI_GATEWAYS="libri-gateway:8953 suki-gateway:8954",
    DEPLOY_LIBRI_INSTANCES="",
    DEPLOY_LIBRI_HIPPOS="",
    DEPLOY_LIBRI_ADDONS="boards computer connect",
    DEPLOY_LIBRI_SERVED_ADDONS="libri-addon-boards:boards suki-addon-boards:boards",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
requests = [line.split()[-1] for line in (stubs / "requests").read_text().splitlines()]
check("multi-assistant deploy updates connect+computer links and restarts both cores, per-assistant addons, and both gateways",
      code == 0
      and os.readlink(addons_dir / "connect") == new_connect
      and os.readlink(addons_dir / "computer") == new_computer
      and restarts == [
          "libri-core.service",
          "suki-core.service",
          "libri-addon-boards.service",
          "suki-addon-boards.service",
          "libri-gateway.service",
          "suki-gateway.service",
      ]
      and requests == ["http://127.0.0.1:8953/", "http://127.0.0.1:8954/"]
      and (addons_dir / ".boards.ran").read_text().strip() == b2
      and (addons_dir / ".suki-addon-boards.ran").read_text().strip() == b2,
      f"code {code}, restarts {restarts}, requests {requests}")
(stubs / "restarts").unlink()
(stubs / "requests").unlink()
# Repeat deploy with unchanged binaries skips both per-assistant served add-ons.
code = deploy(
    repo, stubs, "ok", "200", NEW=new,
    ACTIVE="libri-gateway.service suki-gateway.service",
    DEPLOY_LIBRI_CORES="libri-core suki-core",
    DEPLOY_LIBRI_GATEWAYS="libri-gateway:8953 suki-gateway:8954",
    DEPLOY_LIBRI_INSTANCES="",
    DEPLOY_LIBRI_HIPPOS="",
    DEPLOY_LIBRI_ADDONS="boards computer connect",
    DEPLOY_LIBRI_SERVED_ADDONS="libri-addon-boards:boards suki-addon-boards:boards",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("multi-assistant repeat deploy skips unchanged per-assistant served addons",
      code == 0
      and restarts == [
          "libri-core.service",
          "suki-core.service",
          "libri-gateway.service",
          "suki-gateway.service",
      ],
      f"code {code}, restarts {restarts}")
shutil.rmtree(root)

# Multi-assistant second-gateway health failure rolls back both cores, both
# per-assistant served add-ons, both gateways, and connect+computer links.
root, repo, stubs = scratch()
old, new = build(stubs, "old", "h1", core=True), build(stubs, "new", "h2", core=True)
(stubs / "link").unlink()
os.symlink(old, stubs / "link")
addons_dir = stubs / "addons"
addons_dir.mkdir()
old_boards, b1 = addon_build(stubs, "boards", "old", "b1")
new_boards, _ = addon_build(stubs, "boards", "new", "b2")
old_connect, _ = addon_build(stubs, "connect", "old", "c1")
new_connect, _ = addon_build(stubs, "connect", "new", "c2")
os.symlink(old_boards, addons_dir / "boards")
os.symlink(old_connect, addons_dir / "connect")
(addons_dir / ".boards.ran").write_text(b1 + "\n")
(addons_dir / ".suki-addon-boards.ran").write_text(b1 + "\n")
new_dir = stubs / "new-addons"
new_dir.mkdir()
os.symlink(new_boards, new_dir / "boards")
os.symlink(new_connect, new_dir / "connect")
code = deploy(
    repo, stubs, "ok", "200", NEW=new,
    ACTIVE="libri-gateway.service suki-gateway.service",
    SUKI_GATEWAY_HEALTH="500",
    DEPLOY_LIBRI_CORES="libri-core suki-core",
    DEPLOY_LIBRI_GATEWAYS="libri-gateway:8953 suki-gateway:8954",
    DEPLOY_LIBRI_INSTANCES="",
    DEPLOY_LIBRI_HIPPOS="",
    DEPLOY_LIBRI_ADDONS="boards connect",
    DEPLOY_LIBRI_SERVED_ADDONS="libri-addon-boards:boards suki-addon-boards:boards",
    DEPLOY_LIBRI_ADDONS_DIR=str(addons_dir),
    ADDON_NEW_DIR=str(new_dir),
)
restarts = (stubs / "restarts").read_text().splitlines()
check("multi-assistant gateway health failure rolls back all cores, addons, and gateways",
      code != 0
      and os.readlink(stubs / "link") == old
      and os.readlink(addons_dir / "boards") == old_boards
      and os.readlink(addons_dir / "connect") == old_connect
      and restarts == [
          "libri-core.service",
          "suki-core.service",
          "libri-addon-boards.service",
          "suki-addon-boards.service",
          "libri-gateway.service",
          "suki-gateway.service",
          "libri-core.service",
          "suki-core.service",
          "libri-addon-boards.service",
          "suki-addon-boards.service",
          "libri-gateway.service",
          "suki-gateway.service",
      ]
      and (addons_dir / ".boards.ran").read_text().strip() == b1
      and (addons_dir / ".suki-addon-boards.ran").read_text().strip() == b1,
      f"code {code}, restarts {restarts}")
shutil.rmtree(root)

if failures:
    sys.exit(f"{len(failures)} failed")
print("all checks passed")
