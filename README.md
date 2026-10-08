# Monix

NixOS configuration for four machines, in one flake. Hosts deploy with
`switcharoo`, which pulls `origin/main` and switches, so only published
commits ever reach a machine.

| Host  | Machine                  | Role |
|-------|--------------------------|------|
| water | Threadripper workstation | Home server, AI system, desktop |
| fire  | Gaming desktop           | Workstation, local inference |
| earth | Framework 13             | Laptop |
| air   | Cloud VPS                | Public sites, tailnet DNS filtering |

Private services are reachable only over Tailscale.

The repository has four systems: Platform, Desktop, AI and Homelab.

## Platform

The flake follows the dendritic pattern. Every `*.mod.nix` file is a
flake-parts module and is imported automatically. Modules add themselves to
named bundles (`default`, `desktop`, `hyprland`, `dev`, `lab`, `web`), and a
host file is just its bundles plus hardware. There are no per-service
`enable` flags; the bundles a host imports decide what it runs.
Conventions are in `AGENTS.md`.

`lib.ship` is the shared library, available in every module: the host
constructor, systemd hardening presets, network fences and the AI system's
topology.

Secrets use agenix with host SSH keys. Water unlocks its disk with the TPM
so it can boot unattended. Air runs the tailnet's ad-blocking resolver.

## Desktop

Hyprland with Kestrel, a custom Quickshell (QML) shell that replaces a desktop
environment: bar, menus, launcher, notifications, quick settings and a
settings panel. Its source is in `modules/desktop/shell/`.

## AI

Coding agents run in `bridge`, an unprivileged account with no admin rights
and no host secrets. A network fence keeps it off the LAN and the tailnet.
It can push to this repo; only the captain switches a host onto it.

Agent memory has three parts. **OptMem** (`memo`) is an append-only log of
notes, summarised into a tree that each session loads. The **transcript
archive** keeps every agent conversation on the NAS. **hippo** records
conversations live and summarises them for later sessions.

The agents hand work to a **fleet** of disposable microVMs. The VMs have no
tailnet, repo or secrets, reach the internet only through an allowlist proxy,
and reset after every task. Dispatch goes through a separate unprivileged
operator account. Usage is in `FLEET.md`, which is generated from
`lib/fleet-guide.nix`.

Water and fire serve local models through llama.cpp and llama-swap. Paseo
gives remote clients access to the agents. **Remy** is the household Matrix
bot, running on the local model; it maps chat only to fixed actions, so no
message can reach a shell or the fleet.

## Homelab

Water runs the house's services: an encrypted NAS with verified nightly
backups (see `modules/homelab/nas/README.md`), Jellyfin and the *arr stack,
Immich, Frigate, Home Assistant, a private Matrix server and Minecraft.

Web UIs are served at `<service>.su.is`. The names resolve publicly but route
only inside the tailnet. Services run with systemd hardening and
network fences. Failures, disk warnings and UPS events are posted to a Matrix
alert room.
