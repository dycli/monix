"""The atlas scanner: reads every repository and writes the one JSON file
the atlas site draws.

For each repository it lists the files at HEAD, counts their lines by
language, keeps each file's opening doc comment, follows its imports to
other files, and reads the git history for when each file last changed.
monix gets more: the system data evaluated from Nix at build time (hosts,
services, routes, which module configures which) is joined onto its
modules, and the guided tours in tours.toml are checked against the tree.

    atlas.py scan --mirrors DIR --system FILE --out FILE [--cache DIR]
    atlas.py check --tree DIR --tours FILE

`check` runs in `nix flake check`, so a tour naming a file that has moved
fails the build instead of quietly pointing nowhere.

Standard library only: it runs in the build sandbox and on the server.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import tomllib
from pathlib import PurePosixPath

# ── Languages ────────────────────────────────────────────────────────────

C_LIKE = (["//"], [("/*", "*/")])
HASH = (["#"], [])

# extension → (language, kind, (line comments, block comments))
LANGS = {
    ".rs": ("Rust", "code", C_LIKE),
    ".nix": ("Nix", "code", (["#"], [("/*", "*/")])),
    ".ts": ("TypeScript", "code", C_LIKE),
    ".tsx": ("TypeScript", "code", C_LIKE),
    ".mts": ("TypeScript", "code", C_LIKE),
    ".js": ("JavaScript", "code", C_LIKE),
    ".mjs": ("JavaScript", "code", C_LIKE),
    ".jsx": ("JavaScript", "code", C_LIKE),
    ".py": ("Python", "code", HASH),
    ".qml": ("QML", "code", C_LIKE),
    ".sh": ("Shell", "code", HASH),
    ".bash": ("Shell", "code", HASH),
    ".zsh": ("Shell", "code", HASH),
    ".nu": ("Shell", "code", HASH),
    ".c": ("C", "code", C_LIKE),
    ".h": ("C", "code", C_LIKE),
    ".cpp": ("C++", "code", C_LIKE),
    ".hpp": ("C++", "code", C_LIKE),
    ".go": ("Go", "code", C_LIKE),
    ".lua": ("Lua", "code", (["--"], [])),
    ".sql": ("SQL", "code", (["--"], [("/*", "*/")])),
    ".css": ("CSS", "code", ([], [("/*", "*/")])),
    ".scss": ("CSS", "code", C_LIKE),
    ".html": ("HTML", "code", ([], [("<!--", "-->")])),
    ".glsl": ("GLSL", "code", C_LIKE),
    ".wgsl": ("GLSL", "code", C_LIKE),
    ".frag": ("GLSL", "code", C_LIKE),
    ".vert": ("GLSL", "code", C_LIKE),
    ".asm": ("Assembly", "code", ([";"], [])),
    ".s": ("Assembly", "code", ([";", "#"], [])),
    ".toml": ("TOML", "config", HASH),
    ".yaml": ("YAML", "config", HASH),
    ".yml": ("YAML", "config", HASH),
    ".json": ("JSON", "config", ([], [])),
    ".jinja": ("Template", "config", ([], [("{#", "#}")])),
    ".conf": ("Config", "config", HASH),
    ".ini": ("Config", "config", ([";", "#"], [])),
    ".kdl": ("Config", "config", C_LIKE),
    ".tsv": ("Data", "data", ([], [])),
    ".csv": ("Data", "data", ([], [])),
    ".md": ("Markdown", "docs", ([], [("<!--", "-->")])),
}
NAMES = {
    "Makefile": ("Make", "code", HASH),
    "Dockerfile": ("Docker", "code", HASH),
    "justfile": ("Make", "code", HASH),
    ".zshrc": ("Shell", "code", HASH),
    ".bashrc": ("Shell", "code", HASH),
    ".profile": ("Shell", "code", HASH),
    ".zprofile": ("Shell", "code", HASH),
    "LICENSE": ("License", "docs", ([], [])),
}
SHEBANG = {"sh": "Shell", "bash": "Shell", "zsh": "Shell", "python3": "Python", "python": "Python"}

# Generated or vendored: listed nowhere, they would drown what was written.
SKIP_NAMES = {"Cargo.lock", "package-lock.json", "flake.lock", "yarn.lock", "pnpm-lock.yaml", "uv.lock"}
SKIP_DIRS = {"node_modules", "target", "dist", ".git", "__pycache__", "result"}
# Hand-written files are small; a "config" past this is data in disguise.
CONFIG_MAX = 60_000


def classify(path, head):
    """(language, kind, comment syntax) of a file, or None when binary."""
    if b"\0" in head[:8000]:
        return None
    p = PurePosixPath(path)
    if p.name in NAMES:
        return NAMES[p.name]
    if p.suffix.lower() in LANGS:
        return LANGS[p.suffix.lower()]
    if head.startswith(b"#!"):
        first = head.split(b"\n", 1)[0].decode(errors="replace")
        prog = first.split()[-1] if "env" in first else first.split("/")[-1].split()[0]
        if prog in SHEBANG:
            return (SHEBANG[prog], "code", HASH)
    return ("Text", "data", ([], []))


def count(text, syntax):
    """(code, comment, blank) line counts."""
    line, block = syntax
    code = comment = blank = 0
    inside = None
    for raw in text.split("\n"):
        s = raw.strip()
        if inside:
            comment += 1
            if inside in s:
                inside = None
            continue
        if not s:
            blank += 1
            continue
        if any(s.startswith(c) for c in line):
            comment += 1
            continue
        opened = next((b for b in block if s.startswith(b[0])), None)
        if opened:
            comment += 1
            if opened[1] not in s[len(opened[0]) :]:
                inside = opened[1]
            continue
        code += 1
    return code, comment, blank


# ── Doc comments ─────────────────────────────────────────────────────────


def first_paragraph(lines):
    out = []
    for s in lines:
        if not s.strip():
            if out:
                break
            continue
        out.append(s.strip())
    text = " ".join(out)
    return text[:700] + ("…" if len(text) > 700 else "")


def about(path, text, lang):
    """The file's own opening description, as one paragraph."""
    lines = text.split("\n")[:80]
    if lang == "Markdown":
        body = [s for s in lines if not s.startswith(("#", "![", "<", "---", "|"))]
        return first_paragraph(body)
    if lang == "Rust":
        doc = []
        for s in lines:
            t = s.strip()
            if t.startswith("//!"):
                doc.append(t[3:].strip())
            elif t.startswith(("#![", "//")) or not t:
                if doc and not t:
                    doc.append("")
                continue
            else:
                break
        return first_paragraph(doc)
    if lang == "Python":
        m = re.match(r'\s*(?:#![^\n]*\n)?\s*(?:"""|\'\'\')(.*?)(?:"""|\'\'\')', text, re.S)
        if m:
            return first_paragraph(m.group(1).split("\n"))
    prefixes = {"Nix": "#", "Shell": "#", "Python": "#", "TOML": "#", "Make": "#", "YAML": "#"}
    prefix = prefixes.get(lang, "//")
    doc, started = [], False
    for s in lines:
        t = s.strip()
        if t.startswith("#!") and not started:
            continue
        if t.startswith("/**") or t.startswith("/*"):
            # A block comment: take it whole.
            block = text[text.index(t) :].split("*/", 1)[0]
            doc = [re.sub(r"^\s*(/\*\*?|\*)\s?", "", b) for b in block.split("\n")]
            break
        if t.startswith(prefix) and not t.startswith(prefix + "!"):
            started = True
            doc.append(t[len(prefix) :].lstrip("/# ").rstrip())
            continue
        if not t and not started:
            continue
        break
    return first_paragraph(doc)


# ── Imports ──────────────────────────────────────────────────────────────


def rust_refs(path, text, files):
    """Files of the same crate this Rust file names: `mod x;`, crate::,
    super:: and self:: paths, braces expanded. Resolved at module grain."""
    p = PurePosixPath(path)
    root = next((a for a in p.parents if str(a / "Cargo.toml") in files or (a / "Cargo.toml").as_posix() in files), None)
    src = (root / "src") if root is not None else None
    if src is None or src not in p.parents:
        return []
    parts = list(p.relative_to(src).with_suffix("").parts)
    if parts and parts[-1] == "mod":
        parts = parts[:-1]
    if parts in (["main"], ["lib"]) or (parts and parts[0] == "bin"):
        parts = []
    me = parts

    def resolve(segs):
        for n in range(len(segs), 0, -1):
            base = src.joinpath(*segs[:n])
            for cand in (base.with_suffix(".rs"), base / "mod.rs"):
                if cand.as_posix() in files:
                    return cand.as_posix()
        return None

    found = {}

    def add(segs):
        f = resolve(segs)
        if f and f != path:
            found[f] = found.get(f, 0) + 1

    body = re.sub(r"//[^\n]*", "", text)
    for m in re.finditer(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;", body, re.M):
        add(me + [m.group(1)])

    def expand(prefix, rest):
        rest = rest.strip()
        if rest.startswith("{"):
            depth, cur, items = 0, "", []
            for ch in rest[1:]:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    if depth == 0:
                        break
                    depth -= 1
                if ch == "," and depth == 0:
                    items.append(cur)
                    cur = ""
                else:
                    cur += ch
            items.append(cur)
            for it in items:
                it = it.strip()
                if it:
                    expand(prefix, it)
            return
        m = re.match(r"([\w:]+)(::\{.*)?", rest, re.S)
        if not m:
            return
        segs = [s for s in m.group(1).split("::") if s]
        if m.group(2):
            expand(prefix + segs, m.group(2)[2:])
        else:
            add(prefix + segs)

    for m in re.finditer(r"\b(crate|super|self)::((?:\w+::)*(?:\w+|\{[^;]*?\}))", body):
        head, rest = m.group(1), m.group(2)
        base = [] if head == "crate" else (me[:-1] if head == "super" else me)
        expand(base, rest)
    return sorted(found.items())


JS_EXT = ["", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".css", "/index.ts", "/index.tsx", "/index.js"]


def rel_resolve(base, ref, files, dirs, exts=("",)):
    target = os.path.normpath(os.path.join(base, ref)).replace("\\", "/")
    for e in exts:
        if target + e in files:
            return target + e
    if target in dirs:
        return target
    return None


def refs(path, text, lang, files, dirs, qml):
    base = str(PurePosixPath(path).parent)
    base = "" if base == "." else base
    out = {}

    def add(t, n=1):
        if t and t != path:
            out[t] = out.get(t, 0) + n

    if lang == "Rust":
        return rust_refs(path, text, files)
    if lang in ("TypeScript", "JavaScript"):
        for m in re.finditer(r"""(?:from\s+|import\s*\(\s*|import\s+|require\s*\(\s*)['"](\.{1,2}/[^'"]+)['"]""", text):
            add(rel_resolve(base, m.group(1), files, dirs, JS_EXT))
    elif lang == "Python":
        for m in re.finditer(r"^\s*(?:from\s+\.?(\w+)\s+import|import\s+(\w+))", text, re.M):
            add(rel_resolve(base, (m.group(1) or m.group(2)) + ".py", files, dirs))
    elif lang == "Nix":
        for m in re.finditer(r"(?<![\w/.])(\.\.?/[\w./+-]*[\w+-])", text):
            add(rel_resolve(base, m.group(1), files, dirs))
    elif lang in ("C", "C++"):
        for m in re.finditer(r'#include\s+"([^"]+)"', text):
            add(rel_resolve(base, m.group(1), files, dirs))
    elif lang == "QML":
        here = qml.get(base, {})
        for m in re.finditer(r"^\s*([A-Z]\w+)\s*\{", text, re.M):
            add(here.get(m.group(1)))
        for m in re.finditer(r'^\s*import\s+"([^"]+)"', text, re.M):
            d = rel_resolve(base, m.group(1), files, dirs)
            for name, f in qml.get(d, {}).items():
                if re.search(r"\b" + name + r"\s*\{", text):
                    add(f)
    return sorted(out.items())


# ── Reading a repository ─────────────────────────────────────────────────


class Git:
    """A bare repository, read at HEAD without a checkout."""

    def __init__(self, path):
        self.path = path

    def run(self, *args, binary=False):
        r = subprocess.run(
            ["git", "-c", "safe.directory=*", "-C", self.path, *args],
            capture_output=True,
            check=True,
        )
        return r.stdout if binary else r.stdout.decode(errors="replace")

    def head(self):
        return self.run("rev-parse", "HEAD").strip()

    def files(self):
        out = []
        for line in self.run("ls-tree", "-r", "-l", "-z", "HEAD").split("\0"):
            if not line:
                continue
            meta, path = line.split("\t", 1)
            mode, typ, sha, size = meta.split()
            if typ == "blob" and mode != "120000":
                out.append((path, int(size), sha))
        return out

    def blobs(self, shas):
        """Contents by sha, through one `git cat-file --batch`."""
        if not shas:
            return {}
        proc = subprocess.run(
            ["git", "-c", "safe.directory=*", "-C", self.path, "cat-file", "--batch"],
            input=("\n".join(shas) + "\n").encode(),
            capture_output=True,
            check=True,
        )
        data, out, i = proc.stdout, {}, 0
        for sha in shas:
            nl = data.index(b"\n", i)
            header = data[i:nl].split()
            size = int(header[2])
            out[sha] = data[nl + 1 : nl + 1 + size]
            i = nl + 1 + size + 1
        return out

    def history(self):
        """Per path (last change, commit count); every commit's time; and
        HEAD's subject."""
        log = self.run("log", "--no-renames", "--format=%x00%ct", "--name-only", "HEAD")
        last, counts, times = {}, {}, []
        for chunk in log.split("\0")[1:]:
            lines = chunk.strip("\n").split("\n")
            t = int(lines[0])
            times.append(t)
            for p in lines[1:]:
                if p:
                    last.setdefault(p, t)
                    counts[p] = counts.get(p, 0) + 1
        subject = self.run("log", "-1", "--format=%s", "HEAD").strip()
        return last, counts, times, subject


class Tree:
    """A plain directory, for `check` in the build sandbox."""

    def __init__(self, path):
        self.path = path

    def files(self):
        out = []
        for d, subdirs, names in os.walk(self.path):
            subdirs[:] = [s for s in subdirs if s not in SKIP_DIRS]
            for n in names:
                full = os.path.join(d, n)
                if os.path.islink(full):
                    continue
                rel = os.path.relpath(full, self.path)
                out.append((rel, os.path.getsize(full), full))
        return out

    def blobs(self, keys):
        return {k: open(k, "rb").read() for k in keys}


def skipped(path, size):
    parts = PurePosixPath(path).parts
    return PurePosixPath(path).name in SKIP_NAMES or any(p in SKIP_DIRS for p in parts[:-1])


def read_repo(name, source, history=None):
    """The repository's tree: nested dirs, each file with its counts."""
    listing = [(p, s, k) for p, s, k in source.files() if not skipped(p, s)]
    # Big files are read for their head only; the rest whole.
    contents = source.blobs([k for p, s, k in listing])
    files = {p for p, _, _ in listing}
    dirs = set()
    for p in files:
        for a in PurePosixPath(p).parents:
            if str(a) != ".":
                dirs.add(a.as_posix())
    qml = {}
    for p in files:
        if p.endswith(".qml"):
            d = str(PurePosixPath(p).parent)
            qml.setdefault("" if d == "." else d, {})[PurePosixPath(p).stem] = p

    last, counts, _, _ = history or ({}, {}, [], "")
    nodes = {}
    for path, size, key in listing:
        data = contents[key]
        c = classify(path, data[:8000])
        node = {"name": PurePosixPath(path).name, "path": path, "bytes": size}
        if c is None:
            node["kind"] = "asset"
        else:
            lang, kind, syntax = c
            if kind == "config" and size > CONFIG_MAX:
                kind = "data"
            node["lang"], node["kind"] = lang, kind
            if kind == "data" and size > 200_000:
                node["lines"] = data.count(b"\n")
                node["code"], node["comment"], node["blank"] = node["lines"], 0, 0
            else:
                text = data.decode(errors="replace")
                code, com, blank = count(text, syntax)
                node["lines"] = code + com
                node["code"], node["comment"], node["blank"] = code, com, blank
                if kind != "data":
                    a = about(path, text, lang)
                    if a:
                        node["about"] = a
                    r = refs(path, text, lang, files, dirs, qml)
                    if r:
                        node["refs"] = [[t, n] for t, n in r]
        if path in last:
            node["changed"] = last[path]
            node["commits"] = counts[path]
        nodes[path] = node

    root = {"name": name, "path": "", "children": {}}
    for path in sorted(nodes):
        cur = root
        parts = PurePosixPath(path).parts
        for i, part in enumerate(parts[:-1]):
            sub = "/".join(parts[: i + 1])
            cur = cur["children"].setdefault(part, {"name": part, "path": sub, "children": {}})
        cur["children"][parts[-1]] = nodes[path]

    def describe(d):
        """A directory's description: its README, crate or package
        description, or its crate root's doc comment."""
        kids = d["children"]
        for n in ("README.md", "readme.md", "README"):
            if n in kids and kids[n].get("about"):
                return kids[n]["about"]
        if "Cargo.toml" in kids:
            m = re.search(r'^description\s*=\s*"([^"]+)"', contents_of(kids["Cargo.toml"]), re.M)
            if m:
                return m.group(1)
        if "package.json" in kids:
            try:
                desc = json.loads(contents_of(kids["package.json"])).get("description")
                if desc:
                    return desc
            except ValueError:
                pass
        for sub in ("src", ""):
            holder = kids.get(sub, {}).get("children", {}) if sub else kids
            for n in ("main.rs", "lib.rs", "mod.rs", "default.nix", "main.py", "main.ts", "main.tsx"):
                if n in holder and holder[n].get("about"):
                    return holder[n]["about"]
        return ""

    keyed = {p: k for p, _, k in listing}

    def contents_of(node):
        return contents[keyed[node["path"]]].decode(errors="replace")

    def finish(d):
        if "children" not in d:
            return d
        kids = [finish(c) for c in d["children"].values()]
        a = describe(d)
        d["children"] = sorted(kids, key=lambda c: c["name"])
        if a:
            d["about"] = a
        return d

    return finish(root)


def weekly(times, now, weeks=52):
    counts = [0] * weeks
    for t in times:
        w = int((now - t) // (7 * 86400))
        if 0 <= w < weeks:
            counts[weeks - 1 - w] += 1
    return counts


def scan_repo(path, cache):
    name = os.path.basename(path).removesuffix(".git")
    git = Git(path)
    try:
        head = git.head()
    except subprocess.CalledProcessError:
        return None  # an empty repository
    cached = os.path.join(cache, f"{name}-{head}.json") if cache else None
    if cached and os.path.exists(cached):
        with open(cached) as f:
            return json.load(f)
    history = git.history()
    last, counts, times, subject = history
    tree = read_repo(name, git, history)
    repo = {
        "name": name,
        "head": head,
        "subject": subject,
        "commits": len(times),
        "first": min(times) if times else None,
        "last": max(times) if times else None,
        "times": times,
        "about": tree.get("about", ""),
        "tree": tree,
    }
    if cached:
        os.makedirs(cache, exist_ok=True)
        for old in os.listdir(cache):
            if old.startswith(name + "-") and old.endswith(".json") and len(old) == len(name) + 46:
                os.remove(os.path.join(cache, old))
        tmp = cached + ".part"
        with open(tmp, "w") as f:
            json.dump(repo, f)
        os.replace(tmp, cached)
    return repo


# ── monix: modules and the system ────────────────────────────────────────

AREA = {
    "ai": "ai",
    "homelab": "homelab",
    "desktop": "desktop",
    "networking": "networking",
    "cli": "cli",
    "web": "web",
    "core": "foundation",
}


def flatten(tree):
    out = {}

    def walk(n):
        out[n["path"]] = n
        for c in n.get("children", []):
            walk(c)

    walk(tree)
    return out


def under(paths, prefix):
    return [p for p in paths if p == prefix or p.startswith(prefix + "/")]


def modules(nodes):
    """Group monix's files into modules: a host's directory; each
    `<name>.mod.nix` with its same-named directory and the files it names
    by relative path; each library file."""
    files = sorted(p for p, n in nodes.items() if "children" not in n)
    mods, owner = {}, {}

    def claim(mid, paths):
        for p in paths:
            if p in nodes and "children" not in nodes[p] and p not in owner:
                owner[p] = mid
                mods[mid]["files"].append(p)

    for host in sorted({p.split("/")[1] for p in files if p.startswith("hosts/") and p.count("/") >= 2}):
        mid = f"hosts/{host}"
        mods[mid] = {"id": mid, "name": host, "area": "hosts", "files": [], "entry": f"hosts/{host}/{host}.mod.nix"}
        claim(mid, under(files, mid))

    for f in files:
        if not f.endswith(".mod.nix") or f in owner:
            continue
        p = PurePosixPath(f)
        top = p.parts[0]
        area = "foundation" if top in ("options", "lib") else AREA.get(p.parts[1] if top == "modules" and len(p.parts) > 2 else "", "foundation")
        name = p.name.removesuffix(".mod.nix")
        mods[f] = {"id": f, "name": name, "area": area, "files": [], "entry": f}
        claim(f, [f])
        claim(f, under(files, (p.parent / name).as_posix()))

    # A module alone in a directory of its name (shell/shell.mod.nix)
    # owns the rest of that directory, after its neighbours took theirs.
    for mid in list(mods):
        p = PurePosixPath(mid)
        if p.name.endswith(".mod.nix") and p.parent.name == p.name.removesuffix(".mod.nix"):
            claim(mid, under(files, p.parent.as_posix()))

    # Then what each names by relative path, so a file another module
    # merely mentions stays with the module it sits beside.
    for mid in list(mods):
        if mid.endswith(".mod.nix"):
            for t, _ in nodes[mid].get("refs", []):
                claim(mid, under(files, t))

    for f in files:
        if f.startswith("lib/") and f.endswith(".nix") and f not in owner:
            name = PurePosixPath(f).stem
            mid = f
            mods[mid] = {"id": mid, "name": "lib." + name, "area": "foundation", "files": [], "entry": f}
            claim(mid, [f])
    # Files a module's own files reach (the code a site's build names).
    changed = True
    while changed:
        changed = False
        for mid, m in mods.items():
            for f in list(m["files"]):
                for t, _ in nodes[f].get("refs", []):
                    for g in under(files, t):
                        if g not in owner:
                            claim(mid, [g])
                            changed = True
    return mods, owner


def join_system(tree, system):
    """monix's modules, with what Nix knows about each, and the links
    between them."""
    nodes = flatten(tree)
    mods, owner = modules(nodes)
    for m in mods.values():
        e = nodes.get(m["entry"], {})
        m["about"] = e.get("about") or nodes.get(m["id"], {}).get("about", "")
        m["lines"] = sum(nodes[f].get("lines", 0) for f in m["files"] if nodes[f].get("kind") in ("code", "config", "docs"))
        m.update(hosts=[], services=[], routes=[], secrets=[], options=[])

    hosts = system.get("hosts", [])
    links = {}

    def link(a, b, kind, via):
        if a and b and a != b:
            l = links.setdefault((a, b, kind), set())
            l.add(via)

    def home(unit, files):
        """The file a unit belongs to among those defining it: the one
        named for it, else the first outside a host's own files."""
        named = [f for f in files if f in owner and mods[owner[f]]["name"] in unit]
        # An upstream module defines the unit and ours only tune it.
        alike = [m["entry"] for m in mods.values() if m["name"] == unit]
        shared = [f for f in files if not f.startswith("hosts/")]
        return (named or alike or shared or files)[0]

    declares = {}  # namespace → module
    for h in hosts:
        for f in h["files"]:
            if f in owner and h["name"] not in mods[owner[f]]["hosts"]:
                mods[owner[f]]["hosts"].append(h["name"])
        for o in h["options"]:
            for d in o["declared"]:
                if d in owner:
                    m = mods[owner[d]]
                    if o["name"] not in m["options"]:
                        m["options"].append(o["name"])
                    declares[o["name"].split(".")[0]] = owner[d]
                    for s in o["set"]:
                        link(owner.get(s), owner[d], "configures", o["name"])
        for unit, s in h["services"].items():
            for f in [home(unit, s["files"])]:
                if f in owner:
                    m = mods[owner[f]]
                    if not any(x["name"] == unit for x in m["services"]):
                        m["services"].append({"name": unit, "about": s["description"], "timer": s["timer"], "hosts": [h["name"]], "after": s["after"]})
                    else:
                        x = next(x for x in m["services"] if x["name"] == unit)
                        if h["name"] not in x["hosts"]:
                            x["hosts"].append(h["name"])
                    for dep in s["after"]:
                        d = h["services"].get(dep)
                        if d:
                            link(owner[f], owner.get(home(dep, d["files"])), "starts after", f"{unit} → {dep}")
        for name, r in h["routes"].items():
            for f in r["files"][:1]:
                if f in owner:
                    m = mods[owner[f]]
                    if not any(x["name"] == name for x in m["routes"]):
                        m["routes"].append({"name": name, "subdomain": r["subdomain"], "port": r["port"], "static": r["static"], "host": h["name"]})
                    link(owner[f], "modules/homelab/ship-proxy.mod.nix", "served by", r["subdomain"])
        for name, fs in h["secrets"].items():
            for f in fs:
                if f in owner and name not in mods[owner[f]]["secrets"]:
                    mods[owner[f]]["secrets"].append(name)

    # Reads: `config.<namespace>` in a module's Nix, and `lib.ship.<name>`.
    libs = {m["name"].removeprefix("lib."): mid for mid, m in mods.items() if m["name"].startswith("lib.")}
    for mid, m in mods.items():
        for f in m["files"]:
            if not f.endswith(".nix"):
                continue
            text = ""
            n = nodes[f]
            text = n.get("_text", "")
            for ns in set(re.findall(r"\bconfig\.([A-Za-z_][\w-]*)", text)):
                if ns in declares:
                    link(mid, declares[ns], "reads", "config." + ns)
            for name in set(re.findall(r"\b(?:lib\.)?ship\.(\w+)", text)) | set(re.findall(r"inherit \(lib\.ship\)\s+([\w\s]+);", text)):
                for part in name.split():
                    if part in libs:
                        link(mid, libs[part], "uses", "lib.ship." + part)
            # Secrets read by name.
            for s in set(re.findall(r"\bsecrets\.([\w-]+)\.path", text)):
                m.setdefault("reads_secrets", [])
                if s not in m["reads_secrets"]:
                    m["reads_secrets"].append(s)

    for m in mods.values():
        for k in ("services", "routes", "secrets", "options", "hosts"):
            m[k].sort(key=lambda x: x["name"] if isinstance(x, dict) else x)
    hosts_out = [
        {
            "name": h["name"],
            "system": h["system"],
            "user": h["user"],
            "modules": sorted({owner[f] for f in h["files"] if f in owner}),
            "services": len(h["services"]),
            "routes": len(h["routes"]),
        }
        for h in hosts
    ]
    link_out = [{"source": a, "target": b, "kind": k, "via": sorted(v)} for (a, b, k), v in sorted(links.items())]
    for n in nodes.values():
        n.pop("_text", None)
    return {"hosts": hosts_out, "modules": sorted(mods.values(), key=lambda m: m["id"]), "links": link_out}


def keep_text(repo_source, tree, wanted):
    """Attach the text of monix's Nix files to their nodes for join_system."""
    nodes = flatten(tree)
    listing = {p: k for p, _, k in repo_source.files()}
    keys = [listing[p] for p in nodes if p.endswith(".nix") and p in listing and wanted(p)]
    blobs = repo_source.blobs(keys)
    for p, n in nodes.items():
        if p in listing and listing[p] in blobs:
            n["_text"] = blobs[listing[p]].decode(errors="replace")


# ── Tours ────────────────────────────────────────────────────────────────


def load_tours(text):
    return tomllib.loads(text).get("tour", [])


def check_tours(tours, known):
    """Every focus a tour names, missing from `known` (ids "repo:path" or
    module ids "monix:<module>")."""
    missing = []
    for t in tours:
        for k in ("id", "title", "step"):
            if k not in t:
                missing.append(f"tour {t.get('id', '?')}: no {k}")
        for i, s in enumerate(t.get("step", []), 1):
            for k in ("title", "text"):
                if k not in s:
                    missing.append(f"tour {t['id']} step {i}: no {k}")
            if s.get("view", "wiring") not in ("overview", "map", "wiring", "machines"):
                missing.append(f"tour {t['id']} step {i}: unknown view {s.get('view')}")
            for f in s.get("focus", []):
                if f not in known:
                    missing.append(f"tour {t['id']} step {i}: {f} not found")
    return missing


# ── Commands ─────────────────────────────────────────────────────────────


def known_ids(repos, system):
    ids = set()
    for r in repos:
        for p in flatten(r["tree"]):
            ids.add(f"{r['name']}:{p}" if p else r["name"])
    for m in (system or {}).get("modules", []):
        ids.add("monix:" + m["id"])
    return ids


def mirrored(root):
    """The bare repositories under root, which git-mirror keeps as
    <owner>/<name>.git."""
    for owner in sorted(os.listdir(root)):
        d = os.path.join(root, owner)
        if owner.startswith(".") or not os.path.isdir(d):
            continue
        for entry in sorted(os.listdir(d)):
            path = os.path.join(d, entry)
            if entry.endswith(".git") and os.path.isdir(path):
                yield path


def cmd_scan(a):
    now = time.time()
    repos = []
    system_raw = json.load(open(a.system)) if a.system else {"hosts": []}
    system = None
    tours = []
    for path in mirrored(a.mirrors):
        repo = scan_repo(path, a.cache)
        if repo is None:
            continue
        if repo["name"] == "monix":
            git = Git(path)
            keep_text(git, repo["tree"], lambda p: True)
            system = join_system(repo["tree"], system_raw)
            try:
                tours = load_tours(git.run("show", "HEAD:modules/web/atlas/tours.toml"))
            except subprocess.CalledProcessError:
                tours = []
        repo["weeks"] = weekly(repo.pop("times"), now)
        repos.append(repo)
    missing = check_tours(tours, known_ids(repos, system))
    for m in missing:
        print("atlas: " + m, file=sys.stderr)
    out = {
        "generated": int(now),
        "repos": repos,
        "system": system or {"hosts": [], "modules": [], "links": []},
        "tours": tours,
    }
    tmp = a.out + ".part"
    with open(tmp, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    os.replace(tmp, a.out)
    print(f"atlas: {len(repos)} repositories, {len(out['system']['modules'])} modules, {len(tours)} tours")


def cmd_check(a):
    source = Tree(a.tree)
    tree = read_repo("monix", source)
    keep_text(source, tree, lambda p: True)
    system = join_system(tree, json.load(open(a.system)) if a.system else {"hosts": []})
    tours = load_tours(open(a.tours).read())
    known = known_ids([{"name": "monix", "tree": tree}], system)
    # Other repositories are only on the server; their foci are checked there.
    missing = [m for m in check_tours(tours, known) if not re.search(r"step \d+: (?!monix[:\b])\S+ not found", m)]
    for m in missing:
        print("atlas: " + m, file=sys.stderr)
    if missing:
        sys.exit(1)
    print(f"atlas: {len(tours)} tours, {len(system['modules'])} modules, all foci found")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(required=True)
    s = sub.add_parser("scan")
    s.add_argument("--mirrors", required=True)
    s.add_argument("--system")
    s.add_argument("--out", required=True)
    s.add_argument("--cache")
    s.set_defaults(f=cmd_scan)
    c = sub.add_parser("check")
    c.add_argument("--tree", required=True)
    c.add_argument("--tours", required=True)
    c.add_argument("--system")
    c.set_defaults(f=cmd_check)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
