# Monix

NixOS configuration for four machines, in one flake. Most of it wires up
software other people wrote, and that is not described here. This README
covers what was built: the flake's module system, an AI agent setup with its
own memory, a desktop shell, a household bot with a computer of its own, and
a NAS backup that proves its restores.

| Host  | Machine                  | Role |
|-------|--------------------------|------|
| water | Threadripper workstation | Home server, AI system, desktop |
| fire  | Gaming desktop           | Workstation, local inference |
| earth | Framework 13             | Laptop |
| air   | Cloud VPS                | Public sites, tailnet DNS filtering |

Private services are reachable only over Tailscale.

## Platform

All four hosts are one flake: about 9,100 lines of Nix in 83 modules, four
hosts, two in-tree Rust crates. The layout follows the dendritic pattern, and
most of what makes it work is a few dozen lines of plumbing.

### No import list

`flake.nix` names no modules. It calls flake-parts' `mkFlake` with the repo's
own extended `lib`, and imports every `*.mod.nix` that
`lib.filesystem.listFilesRecursive` finds. Adding a file adds it to the
flake; deleting it removes it. A file's directory is for people only.

Every file is a flake-parts module, and a single file can contribute to
several outputs at once: `hyprland.mod.nix` defines both the compositor
(`nixosModules.hyprland`) and the session (`homeModules.hyprland`). Files are
grouped by concern, not by target, so there is no `home/` tree.

### Aspects and bundles

A module registers an *aspect* and, on the next line, joins a *bundle*:

```nix
flake.nixosModules.frigate = { ... };
flake.nixosModules.lab = self.nixosModules.frigate;
```

The bundles are `default`, `desktop`, `hyprland`, `dev`, `lab` and `web`.
Bundles do not import each other, and none exists without a real member and
a real host importing it.

This needs flake-parts' module collections to behave differently, which
`options/flake-outputs.mod.nix` arranges:

- `nixosModules` and `homeModules` are retyped as lazy attrsets of deferred
  modules, so many files can define the same attribute and the definitions
  merge into one bundle.
- Each definition is keyed by its file and name. An aspect reached through two
  bundles is applied once, so list options are not concatenated twice.
- Every `homeModules.X` is mirrored into `nixosModules.X` as an import of the
  primary user's home. Importing the `hyprland` bundle brings both halves.
  Any other managed user lists its home bundles by name; nothing is gated on
  a username.

There are no per-service `enable` flags. A service applies its config
unconditionally, and a host runs it because it imported the bundle. Only
real per-host facts, such as whether the machine has a UPS, are options.

### Hosts

`lib.ship.host "fire" module` returns a flake-parts module that defines
`nixosConfigurations.fire`, adds the `default` bundle and sets the hostname.
The host file is the machine: its bundle list, `primaryUser`, kernel modules,
firmware, disk layout (disko) and its own secrets, which live beside it in
`hosts/<name>/`. Fire's file is a list of ten bundles and aspects plus its hardware.

### One lib everywhere

`lib/default.nix` extends nixpkgs' lib with `lib.ship`. Hosts are built with
the extended lib's `nixosSystem`, which passes the same lib through the
fixpoint, so flake, NixOS and Home Manager modules all see `lib.ship` without
relative imports. `keys.nix` is the single source of SSH keys, read both by
the agenix CLI and, as `lib.ship.keys`, by the modules that grant SSH access.

### Policies in the plumbing

- **Unfree by name.** There is no `allowUnfree`. A module that installs an
  unfree package adds its name to `unfreePackages` next to the package, and
  `allowUnfreePredicate` admits exactly that list.
- **Style** is in `AGENTS.md`: full `lib` paths, no `rec`. The two rules
  that are easy to slip on, no `builtins.` and no `with lib`, fail the
  flake check.

### lib.ship

`lib/` is the shared library, available in every module as `lib.ship`:

- **Hardening presets** (`hardened.nix`): systemd sandboxing profiles named
  for who the service is. `tenant` is a network service holding untrusted
  input, `rootSensor` a root job that only reads system state, `vendor`
  closed-source software that gets what it needs and no more. A service
  takes a preset and overrides single keys, so the exceptions are visible.
- **Network fences** (`network-fences.nix`): named address sets for
  `IPAddressAllow`/`IPAddressDeny`, applied by name to services and to
  whole user slices. Loopback is a /24, not 127/8: systemd's allow list
  beats its deny list, so the narrower range is what keeps the AI seat's
  own loopback addresses outside it and the seat off other local services.
- **Topology** (`topology.nix`): the AI system's users, uids, paths and
  addresses in one place, so the seat and the hosts it reaches agree.

### Checks

`nix flake check` builds every in-tree Rust crate through `lib.ship.rustTool`,
which runs its tests and `clippy -D warnings` as part of the build. It also
runs nixfmt, rustfmt and the style check, and verifies the agenix rulebook:
every `.age` file has a rule, and every rule points at a tracked file.

### switcharoo

Hosts deploy with `switcharoo`, which starts the root unit
`switcharoo.service` (`modules/core/switcharoo.mod.nix`). It fetches `main`
from a git remote, never a working tree: GitHub, or on Water the NAS
mirror, so a GitHub outage can't block a deploy there. It activates the new
system with `test`, waits for the jobs to settle, and rolls back if
activation failed, a unit newly failed, or a required unit isn't running.
Only a healthy system becomes the boot default. Running as a unit, a switch
finishes even when the SSH session that started it dies; a switch over SSH
that died halfway once left Air without DNS and with a stale sudo.

polkit lets the primary user and the AI seat start it without a password.
Commits touching access, keys or the deploy module itself are fenced:
`switcharoo --approve` deploys them and asks for a wheel password.

## Desktop

The session is Hyprland; everything around it except the shell is stock.

### Kestrel shell

Kestrel is a Quickshell (QML) shell written for this repo, about 9,000
lines in `modules/desktop/shell/` over some 200 commits. It replaces a
desktop environment rather than theming one. The rule is that everything is
reachable from the bar, by keyboard or mouse, and no menu opens a separate
window.

The code is split three ways. *State* singletons own system data (audio,
network, Bluetooth, displays, input, power, notifications, privacy).
*Services* own behaviour, and one `BarModeService` decides which menu is
open on which screen and whether it takes the keyboard, so menus can't stack
or fight over focus. *Popouts* are views that slide out of the bar and close
on Esc or a click outside. Keybinds reach the same services over Quickshell
IPC, so a key and a click take the same path.

- **Menus**: a Pear system menu, Edit, Tools, View, Launch, Find, Clipboard,
  Emoji and a clock with calendar.
- **Settings**: one narrow panel with Audio, Bluetooth, Display (with a live
  preview of the monitor layout), Input (per-mouse settings), Network and
  Power.
- **Status**: notification ticker, privacy indicators for microphone, camera
  and screen sharing, media controls, tray, battery and a power-profile
  carousel.
- **Services**: launcher, on-screen display for volume and brightness, night
  mode, session menu.

## AI

### The seat

Coding agents (Claude Code, Codex, OpenCode, Muse Code) run in `bridge`, one
unprivileged account with a fixed uid. It has no wheel, no Nix trust and no
host secrets. A per-user network fence applies to every process it starts:
it cannot reach the LAN or the tailnet, and reaches the local model server
only through its own address on the seat plane.

Its home is composed in Nix, and one set of managed settings applies to every
launcher, Paseo included, so an agent started from a phone has the same rules
as one in a terminal. It can push to this repo; only the captain switches a
host onto a commit. For the web it drives Libri's agent browser, Chromium on
a private display (`agentBrowser.enable` in `libri.mod.nix`). Its own
graphical session is a headless sway under its systemd user manager
(`seat/desktop.mod.nix`), whose display and session bus Libri, Tern and
Paseo share.

### hippo

hippo is the seat's episodic memory, written in Rust, with seven dependencies.
The design follows Victor Taelin's OptChat: keep every message, and fold the
whole history into a fixed-size summary that any session can read. Its source
lives in Libri (`~/ark/libri/hippo`), and the seat runs the build Libri's deploy
keeps at `/var/lib/libri-build/libri`; `modules/ai/seat/hippo.mod.nix` holds
only its service. [dycli/hippo](https://github.com/dycli/hippo) keeps what monix
last pushed there.

Both the seat's hippo and Suki's run in chat mode: Libri logs each message
and the view is the agent's whole context.

**Recording.** A watcher follows Claude Code, Codex, Muse Code and OpenCode transcripts
as they are written (OpenCode through its SQLite database) and appends each
message to a day-file log. The log is append-only. Secrets of known shapes (API
keys, tokens, private keys, named passwords) are masked before they are
written; masking is best effort, and other secrets get through.
`hippo import` loaded three months of older transcripts, about 9,000
messages.

**Compaction.** Messages become the leaves of a binary tree. Each message is
compressed to a line of at most 512 bytes; each pair of lines is merged into
one line covering both, and so on upward. Lines are tagged by kind (`user`,
`talk`, `tool`, `echo`, `note`), never by chat. The compactor runs Sonnet at
medium effort through the `claude` CLI on the subscription with five-minute
prompt caching; `HIPPO_LEVELS` can hand lower tree levels to a cheaper model. Each call carries the compactions' own view
(the same sawtooth at 16-32 KB, so calls read each other's prefix from the
cache), a ruler of 512 dashes for scale, and the step. When a merge's
two halves come from different chats (keyed by harness and session), the
step says so, so the model does not read one chat as a reply to the other.

**The view.** The view is the history as one block of `id+n|text` lines
within a 128 KB budget, about 60k tokens: recent lines cover one
message each, older lines cover more. Merges come in batches: past 128 KB
the view merges down to 64 KB, then only grows, so its head stays the same
and cached between batches. It is saved and loaded, never refolded at start,
since a refold would differ from the live view. The service rewrites `view.md`
atomically whenever the tree grows.

**Session compaction.** Libri starts each message as a fresh harness session
holding the whole view, so a harness compacts only when one turn fills its
window. Its own summary then serves, and the next message starts clean.

**CLI.** The agent drills down with `zoom` (a line into its two halves, down
to the whole message), `date` and `search` (regex over
every message). `status`, `pause`/`resume`, `audit` and
`replay` serve the operator. The service answers over a unix socket; reads
take 2-15 ms.

**How it was tuned.** Choices were measured rather than guessed:

- Five-minute prompt caching instead of one hour cut the cost per compactor
  call by about two thirds.
- Haiku 5.5, Sonnet, Opus, and OpenAI's Luna and Sol were replayed over the
  same 512 messages and judged blind, by level. Haiku at xhigh matched
  Sonnet when compressing single messages (once a guard held each line to its
  message's kind) and invented at merges, so the model can be chosen by tree
  level. All levels run Sonnet until a week's real cost is known.
- The scale example was first a real history line, then an invented one;
  models copied both into summaries as fact. It is now a ruler of dashes.
- Chat labels were dropped from the tree once they proved unreliable, in
  favour of the session check on merges.

A separate job copies every harness's transcripts to the NAS before the
harnesses prune them.

### Local inference

llama-swap starts one `llama-server` per model on demand and unloads it when
idle, so a host holds no model memory until something asks.

### Libri

The household's assistants are Libri's (`~bridge/ark/libri`),
one per person, each in an endless web chat with a memory of its own:
Bridge for Dylan, on the seat's logins, tools and hippo, and Suki for Gab,
sandboxed under her own user. `modules/ai/libri.mod.nix` is only the host
side: it runs both through Libri's NixOS module, and each runs the build its
link in `/var/lib/libri-build` points at, so the seat rebuilds with no
deploy. Suki's link follows Libri's `stable` branch, so the file writes only
config keys both builds read. Libri's own README covers the program.

What the host adds: pictures, drawn by a small socket-activated service with
Codex on the household's ChatGPT subscription, which alone holds that login;
`usage`, which reports each subscription's limits and who used them; and
`run_code`'s microVM under cloud-hypervisor (`assistant-computer.mod.nix`), which
runs code with no network, in a folder the host fills, on a host-only bridge
with NAT to public addresses only (`assistant-network.mod.nix`). Nothing of the
household goes in: no tailnet, no store share, no secret.

The two assistants reach each other over A2A, the open agent-to-agent
protocol: each names the other as a peer, and both present one token that a
oneshot makes on first start and each unit receives as a credential. A
message lands in the other's chat as a note, and a routine's `share_with`
sends over it. Their memories stay apart.

## Homelab

Water runs the house's services as one bundle, `lab`. Which services they
are matters less than how they are put together.

**One front door.** nginx terminates TLS for every `<service>.su.is` with a
single wildcard certificate, issued by DNS-01 because the host is not
publicly reachable. Each service module declares its own route (subdomain
and port) beside its config, so adding a service touches one file. The names resolve publicly
but route only inside the tailnet, and an explicit default vhost catches any
name with no route.

**A private Matrix server.** tuwunel at chat.su.is, federation off and
registration token-gated, for people's own Matrix clients. No assistant
listens on it.

**Fenced by default.** Each service gets a network fence and only the paths
its job needs, even where a shared group would allow more. Software that
ships no isolation of its own takes the `vendor` preset.

### NAS and backups

Water's NAS is an encrypted Btrfs filesystem on a 4 TB SSD, backed up to an
encrypted Restic repository on an 8 TB HDD (`modules/homelab/nas.mod.nix`).
Bind mounts keep every service's original paths, so moving data onto the NAS
changed no service configuration.

Each night at 03:30 the backup pauses only the Immich server, dumps its
PostgreSQL database, takes a read-only Btrfs snapshot of the SSD and one of
the OS subvolume, and resumes Immich. Restic copies the SSD snapshot and the
OS-disk state no rebuild recreates (Home Assistant, Minecraft, Prowlarr,
Libri, money) to the HDD, then proves the copy: it restores that night's
fresh probe file and the full database dump from the repository, compares
bytes, and parses the dump. Only then does it record a success. It never
creates a repository, so a blank disk fails instead of passing for a good
one. On Sundays it prunes old snapshots and reads back 5% of the stored
data. `nas-backup` runs one by hand; `restic snapshots` and `restic restore`
work from a root shell with the repository at `/srv/backup/restic` and its
password in `/var/lib/nas/restic-password`.
