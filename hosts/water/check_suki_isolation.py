"""Verify Suki's Stage 2 isolation and configuration invariants on Water.

Usage: check_suki_isolation.py MANIFEST_JSON
"""

import json
import re
import sys
import tomllib
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name}" + (f": {detail}" if detail else ""))
        failures.append(name)


def unit_values(unit_text, key):
    prefix = f"{key}="
    return [line[len(prefix):] for line in unit_text.splitlines() if line.startswith(prefix)]


def unit_env(unit_text, var):
    for raw in unit_values(unit_text, "Environment"):
        value = raw[1:-1] if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"' else raw
        if value.startswith(f"{var}="):
            return value[len(var) + 1 :]
    return None


toml_path = Path(manifest["libri_toml"])
toml_text = toml_path.read_text()
toml_data = tomllib.loads(toml_text)

unit_texts = {
    unit: Path(path).read_text() for unit, path in manifest["units"].items()
}

# Forbidden Bridge paths, stores, and MCP servers that must never appear in
# Suki's configuration or any Suki systemd unit.
forbidden_patterns = [
    ("bridge home", re.compile(r"/home/bridge\b")),
    ("bridge libri dir", re.compile(r"/var/lib/libri/")),
    ("bridge libri-core", re.compile(r"/var/lib/libri-core\b")),
    ("bridge libri-gateway", re.compile(r"/var/lib/libri-gateway\b")),
    ("bridge hippo2 dir", re.compile(r"/var/lib/hippo2(?![-\w])")),
    ("bridge storage hippo", re.compile(r"/srv/storage/hippo")),
    ("fastmail", re.compile(r"\bfastmail\b", re.IGNORECASE)),
    ("cloudflare", re.compile(r"\bcloudflare\b", re.IGNORECASE)),
    ("browse mcp", re.compile(r"\[mcp\.browse\]|\blibri-browse\b")),
    ("bridge xai connection", re.compile(r"LIBRI_XAI_CONNECTION")),
]

all_files = {"/etc/libri-suki/libri.toml": toml_text, **unit_texts}
for filename, text in all_files.items():
    hits = [
        f"{label} ({match.group(0)!r})"
        for label, pattern in forbidden_patterns
        if (match := pattern.search(text))
    ]
    check(
        f"{filename} has zero Bridge references",
        not hits,
        ", ".join(hits),
    )

# Suki's Claude harness must enforce narrow built-in tools and strict MCP.
claude = toml_data.get("harness", {}).get("claude", {})
check(
    "libri.toml restricts claude tools to AskUserQuestion",
    claude.get("tools") == ["AskUserQuestion"],
    repr(claude.get("tools")),
)
check(
    "libri.toml enables strict_mcp for claude",
    claude.get("strict_mcp") is True,
    repr(claude.get("strict_mcp")),
)

# Expected MCP servers in /etc/libri-suki/libri.toml.
mcp = toml_data.get("mcp", {})
expected_mcp = {
    "a2a",
    "boards",
    "computer",
    "files",
    "hippo2",
    "home",
    "image",
    "layout",
    "lists",
    "money",
    "pages",
    "search",
    "speech",
    "ui",
    "wiki",
}
missing_mcp = sorted(expected_mcp - set(mcp))
check("libri.toml declares all expected MCP servers", not missing_mcp, repr(missing_mcp))

# hippo2 MCP must use Suki's wrapped binary with forced HIPPO2_HOME=/var/lib/hippo2-suki.
hippo2_cmd = mcp.get("hippo2", {}).get("command", [])
check(
    "mcp.hippo2 invokes hippo2-suki wrapper",
    len(hippo2_cmd) == 2 and hippo2_cmd[1] == "mcp" and "hippo2-suki" in hippo2_cmd[0],
    repr(hippo2_cmd),
)
if hippo2_cmd:
    wrapper_text = Path(hippo2_cmd[0]).read_text()
    check(
        "hippo2-suki wrapper forces HIPPO2_HOME=/var/lib/hippo2-suki",
        "HIPPO2_HOME='/var/lib/hippo2-suki'" in wrapper_text
        or 'HIPPO2_HOME="/var/lib/hippo2-suki"' in wrapper_text
        or "HIPPO2_HOME=/var/lib/hippo2-suki" in wrapper_text,
        wrapper_text,
    )

# Home Assistant MCP uses runtime file reference, never an inline token.
home_auth = mcp.get("home", {}).get("headers", {}).get("Authorization")
check(
    "mcp.home Authorization reads /run/suki-core/home-auth",
    home_auth == {"file": "/run/suki-core/home-auth"},
    repr(home_auth),
)

# Computer add-on points at Suki's desk and files store.
computer_env = mcp.get("computer", {}).get("env", {})
check(
    "mcp.computer targets Suki's microVM runner and desk",
    computer_env.get("LIBRI_RUN", "").startswith("http://10.101.0.")
    and computer_env.get("LIBRI_RUNS_DIR") == "/var/lib/yeoman-desks/suki/runs"
    and computer_env.get("LIBRI_FILES_DIR") == "/var/lib/suki-core/files"
    and computer_env.get("LIBRI_OUTBOX_DIR") == "/var/lib/suki-core/outbox",
    repr(computer_env),
)

# Gateway must restrict tailnet access to Gab and Dylan's metal only.
gw = unit_texts["suki-gateway.service"]
check("suki-gateway enables --tailnet-whois", "--tailnet-whois" in gw)
check(
    "suki-gateway admits gabcaminiti10@gmail.com",
    re.search(r"--tailnet-owner\s+'?gabcaminiti10@gmail\.com'?(?:\s|$)", gw) is not None,
    gw,
)
check(
    "suki-gateway admits ddcleary1@gmail.com/metal",
    re.search(r"--tailnet-owner\s+'?ddcleary1@gmail\.com/metal'?(?:\s|$)", gw) is not None,
    gw,
)
check(
    "suki-gateway does not admit bare ddcleary1@gmail.com",
    re.search(r"--tailnet-owner\s+'?ddcleary1@gmail\.com'?(?:\s|$)", gw) is None,
    gw,
)
check(
    "suki-gateway sets assistant name Suki",
    unit_env(gw, "LIBRI_GATEWAY_ASSISTANT_NAME") == "Suki",
)
check("suki-gateway listens on 127.0.0.1:8954", "127.0.0.1:8954" in gw)

# Core uses isolated system/person config dirs and tenant hardening.
core = unit_texts["suki-core.service"]
check("suki-core sets LIBRI_SYSTEM_CONFIG_DIR=/etc/libri-suki", unit_env(core, "LIBRI_SYSTEM_CONFIG_DIR") == "/etc/libri-suki")
check("suki-core sets LIBRI_CONFIG_DIR=/var/lib/suki-config", unit_env(core, "LIBRI_CONFIG_DIR") == "/var/lib/suki-config")
check("suki-core protects /home", "ProtectHome=true" in core)
check("suki-core uses ProtectSystem=strict", "ProtectSystem=strict" in core)
check("suki-core runs as suki", "User=suki" in core)

denied_ips = set(unit_values(core, "IPAddressDeny"))
required_denied = {
    "10.0.0.0/8",
    "100.64.0.0/10",
    "172.16.0.0/12",
    "192.168.0.0/16",
}
missing_denied = sorted(required_denied - denied_ips)
check(
    "suki-core IPAddressDeny blocks LAN and tailnet",
    not missing_denied,
    f"missing {missing_denied}; got {sorted(denied_ips)}",
)

rw_paths = [
    path
    for entry in unit_values(core, "ReadWritePaths")
    for path in entry.split()
]
check(
    "suki-core ReadWritePaths only includes Suki's desk",
    rw_paths == ["/var/lib/yeoman-desks/suki"],
    repr(rw_paths),
)

# Inbound A2A keeps 127.0.0.1:8952 on Suki's core socket.
a2a = unit_texts["suki-addon-a2a.service"]
check("suki-addon-a2a listens on 127.0.0.1:8952", "127.0.0.1:8952" in a2a)
check("suki-addon-a2a connects to /run/suki-core/client.sock", "/run/suki-core/client.sock" in a2a)

# hippo2-suki is isolated on /var/lib/hippo2-suki and disables legacy libri reader.
hippo = unit_texts["hippo2-suki.service"]
check("hippo2-suki runs as hippo2-suki", "User=hippo2-suki" in hippo)
check("hippo2-suki sets HIPPO2_HOME=/var/lib/hippo2-suki", unit_env(hippo, "HIPPO2_HOME") == "/var/lib/hippo2-suki")
check("hippo2-suki reads /run/suki-core/client.sock", unit_env(hippo, "HIPPO2_LIBRI_CORE_SOCKET") == "/run/suki-core/client.sock")
hippo_off = unit_env(hippo, "HIPPO2_OFF") or ""
check(
    "hippo2-suki disables legacy libri reader",
    re.search(r"(^|,)libri(,|$)", hippo_off) is not None,
    repr(hippo_off),
)

# Legacy suki.service is absent on Water.
check("legacy suki.service is absent on Water", not manifest["has_legacy_suki"])

# Person-layer config dir is root-owned and group-readable (0750 root suki).
config_tmpfile = manifest["suki_config_tmpfile"] or {}
check(
    "/var/lib/suki-config tmpfile is root:suki 0750",
    config_tmpfile.get("user") == "root"
    and config_tmpfile.get("group") == "suki"
    and config_tmpfile.get("mode") == "0750",
    repr(config_tmpfile),
)

if failures:
    sys.exit(f"{len(failures)} suki-isolation checks failed")
print("all suki-isolation checks passed")
