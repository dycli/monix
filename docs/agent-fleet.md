# The agent fleet on fw0

fw0 runs a fleet of worker microVMs in which coding agents (Claude Code,
Codex) run fully-permissioned against exactly one repository each, contained
by the host rather than by anything the guest promises. Two modules implement
it, both gated on `agentFleet.enable`:

- `modules/server/microvm-host.mod.nix` — the host side: microvm.nix runner,
  host-only bridge, squid egress proxy.
- `modules/server/agent-vm.mod.nix` — the guest side: the `workers` roster
  and the `mkAgentGuest` factory that turns each entry into a microVM plus
  its `agents.slice` unit override.

## Containment model

Containment is structural, not rule-based:

- **No route out.** Guests sit on the host-only bridge `br-agents`
  (`10.100.0.1/24`) with a static address, **no default gateway, and no
  DNS**. No uplink is enslaved to the bridge, and no IP forwarding is enabled
  anywhere, so there is nothing to route to even if a guest reconfigures
  itself.
- **One reachable host port.** The firewall on `br-agents` admits only TCP
  3128 (squid). The bridge is not a trusted interface; everything else —
  including DNS and the host's sshd — hits the default drop.
- **Squid is the sole egress path**, bound to the bridge IP, with a
  `dstdomain` CONNECT allowlist (`allowedDomains` in microvm-host.mod.nix)
  and a per-request access log at `/var/log/squid/access.log` — the egress
  audit trail. Squid resolves DNS on the guests' behalf. Anything that isn't
  HTTP(S) via the proxy (ssh-to-github, raw sockets) fails closed; widen the
  allowlist by reviewed commit, never bypass the proxy.
- **Containment by absence.** Workers are built from a minimal inline module
  list, not `self.nixosModules`: no tailnet, no host secrets, no monorepo.
  The host's `/nix/store` is shared read-only over virtiofs (so never put
  secrets in the store).
- **Squid is sandboxed.** It is the one host process that parses bytes from
  the guests, so its unit runs under a strict systemd sandbox (read-only
  filesystem, no new privileges, syscall/capability allowlist limited to the
  root→`squid` privilege drop).

The guest root is tmpfs; only the two per-worker volume images (nix-store
overlay + `/workspace` scratch) persist across restarts. Guests hold no
credentials: no API keys or tokens are injected.

## Networking layout

The host uses systemd-networkd for **all** interfaces (mixing networkd with
scripted DHCP is unsupported): the `en*` uplink keeps plain DHCP, `br-agents`
is declared carrier-less, and `vm-*` taps are auto-enslaved to the bridge by
match. `tailscale0` is left to tailscaled. Worker addresses are
`10.100.0.10+index`; MACs are locally administered with the index as the
last octet.

## Resource fences

Every worker's `microvm@<name>` unit and squid run in `agents.slice`
(48G `MemoryMax`, declared in `hosts/fw0/fw0.mod.nix`). Guest memory is
static (no ballooning), default 8 vCPU / 8 GiB. Guest state lives on the
`@agents` btrfs subvolume (`/var/lib/agents/microvms`).

## Operating a worker

Lifecycle is manual, from the cockpit session on fw0:

```sh
systemctl start microvm@lfish-0     # boot (seconds)
microvm -s lfish-0                  # serial console (root autologin —
                                    # reaching the PTY already requires host root)
ssh agent@10.100.0.11               # from the host; admin keys are authorized
systemctl stop microvm@lfish-0
```

Adding a worker is one entry in the `workers` list in agent-vm.mod.nix; the
VM definition and its slice override are both generated from it.

## Verifying containment

From inside a guest, all of these must fail:

```sh
curl -m5 https://example.com        # proxy 403: not on the allowlist
getent hosts google.com             # no DNS
curl -m5 http://10.100.0.1:22       # no host ports besides 3128
```

And these must succeed, each leaving a line in squid's access log:

```sh
curl -sI https://api.anthropic.com
git ls-remote https://github.com/NixOS/nixpkgs
```

On the host, `systemd-cgls /agents.slice` shows the running VMs and squid
under the slice.
