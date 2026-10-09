# Monix

NixOS configuration for four machines, in one flake. Most of it wires up
software other people wrote, and that is not described here. This README
covers what was built: the flake's module system, an AI agent setup with its
own memory and a fleet of sandboxed VMs, a desktop shell, a household bot,
and a NAS backup that proves its restores.

| Host  | Machine                  | Role |
|-------|--------------------------|------|
| water | Threadripper workstation | Home server, AI system, desktop |
| fire  | Gaming desktop           | Workstation, local inference |
| earth | Framework 13             | Laptop |
| air   | Cloud VPS                | Public sites, tailnet DNS filtering |

Private services are reachable only over Tailscale.

## Platform

The whole fleet is one flake: about 9,200 lines of Nix in 84 modules, four
hosts, six in-tree Rust crates. The layout follows the dendritic pattern, and
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
flake.nixosModules.alerts = { ... };
flake.nixosModules.lab = self.nixosModules.alerts;
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
- **Topology** (`fleet-topology.nix`): the AI system's users, uids, paths
  and addresses in one place, so the seat, fleet and guests agree.

### Checks

`nix flake check` builds every in-tree Rust crate through `lib.ship.rustTool`,
which runs its tests and `clippy -D warnings` as part of the build. It also
runs nixfmt, rustfmt and the style check, and verifies the agenix rulebook:
every `.age` file has a rule, and every rule points at a tracked file.

### switcharoo

Hosts deploy with `switcharoo`. It pulls `origin/main` fast-forward only, so
a host only ever runs published commits. It builds as the user with `nh`, then
activates in a detached `systemd-run` unit. Activation can restart
`tailscaled` or `sshd`; detached, the switch finishes even when the SSH
session that started it dies. A switch over SSH that died halfway once left
Air without DNS and with a stale sudo, which is why it works this way.

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

Coding agents (Claude Code, Codex, OpenCode) run in `bridge`, one
unprivileged account with a fixed uid. It has no wheel, no Nix trust and no
host secrets. A per-user network fence applies to every process it starts:
it cannot reach the LAN or the tailnet, and reaches the local model server
only through its own address on the seat plane.

Its home is composed in Nix, and one set of managed settings applies to every
launcher, Paseo included, so an agent started from a phone has the same rules
as one in a terminal. It can push to this repo; only the captain switches a
host onto a commit. For the web it drives Brave over MCP, either headless
inside the fence or the visible one on a desktop over Tailscale SSH.

### hippo

hippo is the seat's episodic memory: about 4,200 lines of Rust in
`modules/ai/seat/hippo`, with seven dependencies. The design follows Victor
Taelin's OptChat: keep every message, and fold the whole history into a
fixed-size summary that any session can read.

**Recording.** A watcher follows Claude Code, Codex and OpenCode transcripts
as they are written (OpenCode through its SQLite database) and appends each
message to a day-file log. The log is append-only. Secrets are masked before
they are written, and a chat containing `#offrecord` is not recorded.
`hippo import` loaded three months of older transcripts, about 9,000
messages.

**Compaction.** Messages become the leaves of a binary tree. Each message is
compressed to a line of at most 512 bytes; each pair of lines is merged into
one line covering both, and so on upward. Lines are tagged by kind (`user`,
`talk`, `tool`, `echo`, `note`), never by chat. The compactor is Sonnet at
medium effort, run through the `claude` CLI on the subscription, with
five-minute prompt caching. Each call carries the current view as shared
context, an invented 512-byte line for scale, and the step. When a merge's
two halves come from different chats (keyed by harness and session), the
step says so, so the model does not read one chat as a reply to the other.

**The view.** The view is the history as one block of `id+n|text` lines
within a fixed 128 KB budget, about 60k tokens: recent lines cover one
message each, older lines cover more. The service rewrites `view.md`
atomically whenever the tree grows. On the seat, `~/.claude/rules/hippo-view.md`
links to it, so Claude Code loads the whole view at session start and after
every compaction with no tool call. Codex and OpenCode page it in with
`hippo view`.

**Session compaction.** Claude Code compacts at 200k tokens, and a
PreCompact hook has the agent write a short handoff first. A session comes
back as handoff plus fresh view rather than a long transcript summary.
Compactions went from 97-113 seconds to 16-18.

**CLI.** The agent drills down with `zoom` (a line into its two halves, down
to the whole message), `date` and `search` (regex over
every message). `status`, `pause`/`resume`, `browse`, `audit` and
`replay` serve the operator. The service answers over a unix socket; reads
take 2-15 ms.

**How it was tuned.** Choices were measured rather than guessed:

- Five-minute prompt caching instead of one hour cut the cost per compactor
  call by about two thirds.
- Haiku 5.5 was tried as a 12x cheaper compactor over a full day of history,
  across three prompt revisions and two effort levels. It still put wrong
  context into 4-20% of lines against Sonnet's 0%, so Sonnet stayed.
- The scale example was first a real history line, and models copied it into
  summaries as fact. It is now an invented line.
- Chat labels were dropped from the tree once they proved unreliable, in
  favour of the session check on merges.

### OptMem

`memo` (`modules/ai/seat/memo-cli`) is a Rust implementation of Victor
Taelin's OptMem: an append-only log of one-line notes that the agent writes
on purpose (decisions, rules, outcomes), summarised into a binary tree that
`memo wake` prints at the start of every session. `recall` and `find` search
the raw notes; `zoom` opens a tree node; `nap` runs pending compressions.
OptMem runs beside hippo while hippo is on trial. A separate job copies every
harness's transcripts to the NAS before the harnesses prune them.

### The fleet

The seat hands work to drones: disposable microVMs, each running one agent
on one task. The code is about 5,500 lines of Rust in three crates under
`modules/ai/fleet`, and it assumes the agent inside the VM is hostile.

**`fleet` CLI.** The only path from the seat to the queue. It runs through
scoped sudo as `fleet-operator`, a separate account outside wheel. Its
configuration is compiled in, so the caller cannot redirect it. `dispatch`
snapshots the working context and passes it to the task on stdin; the other
commands submit, watch, fetch results and patches, read logs, peek at a
running drone, steer it, answer its questions, cancel, and report status and
health.

**Dispatcher.** One resident drainer per worker keeps a warm VM. It claims a
queued markdown task, runs it, archives the result and reboots the guest.
The queue is capped by bytes and inodes. A task's front matter must name the
agent and model. `guidance: cockpit` lets a drone send questions back to the
seat instead of guessing.

**Guest supervisor.** Inside the VM, the supervisor runs as root and treats
everything it reads as hostile: no symlinks followed, every read bounded, no
shell interpolation. Each agent runs as its own unprivileged user with one
staged credential. The supervisor captures the patch and a usage record, and
writes the exit code last, so a result is complete when it has one.

**Isolation.** Guests are microvm.nix VMs on the host-only `br-agents`
bridge. Their only way out is a Squid allowlist of the model vendors' APIs,
search and docs services, and the Nix cache; local inference is reached
directly. Per-worker volumes are wiped on every start. The VMs have no tailnet, repo or secrets.
Results come back as untrusted input for the seat to review.

The fleet's audit log is streamed to a Matrix room (`log-stream.mod.nix`).
The agents' operating guide is one Nix file, `lib/fleet-guide.nix`, rendered
into `AGENTS.md`, `FLEET.md` and the drone guide, so the seat and the drones
can't drift apart.

### Local inference

llama-swap starts one `llama-server` per model on demand and unloads it when
idle, so a host holds no model memory until something asks.

### Sokka

Sokka (`modules/ai/sokka`) is the household assistant, a small Rust service
on Matrix. It has no sessions and never compacts: every message becomes one
fresh model call over Sokka's prompt, its whole memory and the new message.
The memory is a second hippo store, written directly instead of by
following transcripts: the bot logs each message and each answer, and hippo
folds them into a 128 KB view, the seat's size, so once the view fills an
endless chat costs the same per call on its hundredth day as its thousandth.

The model is configuration: the `claude` CLI on a subscription token, or
any OpenAI-compatible endpoint, local or hosted. The CLI runs with built-in
tools and settings off; its tools come over MCP, and the prompt mentions
them only when the model has them. Web search and fetch go through a short
Python server in front of Parallel's keyless one. Sokka's own server, `sokka tools`, keeps reminders and lists in one
locked JSON book and can touch nothing else, so a page that tries to steer
the model through search results finds no keys, memory or shell to reach.
The calendar is a third server, a short Python one on `caldav` and the
official MCP SDK, and the only process that receives the CalDAV login, as
a systemd credential; it lists, adds, moves and cancels events, with
repeats expanded. Mail is a fourth, read-only over IMAP: folders open with
EXAMINE and bodies are fetched with `BODY.PEEK`, so nothing is moved or
marked read, and it cannot send. Since any sender or page can put text in
front of the model, fetch opens only links that a search in the same call
returned or that the person wrote, as OpenAI's agents do: a link the model
made up could carry what it read out in its path, but a link that existed
before it read anything carries nothing. YouTube is a fifth, on `yt-dlp`: it
searches and reads a video's captions as text, the uploader's own before
automatic ones, and refuses any link that is not YouTube.
Pictures are a sixth: the assistant describes one, and a small socket-activated
service draws it with Codex on the household's ChatGPT subscription. That
service alone holds the Codex login; the assistants reach only its socket. The
picture waits in the instance's outbox, goes out with the answer, encrypted
like any attachment, and is then deleted.
Another socket service, `usage`, reports how much of each subscription's
limits is used (Claude, ChatGPT/Codex, OpenCode Go), read live from each
provider and never stored; the assistants ask it through their tools and the
seat through its `usage` command, and only it sees the logins.
The bot checks the book every 30 seconds and sends due reminders itself,
logging them to hippo like any other answer. A reminder can instead be a
routine ("a mail digest at 8, 2 and 8"): when it comes due, the bot runs its
text as a request, with the same tools as a message from its person, and sends
the answer, or stays quiet when it has nothing new, so a daily price
check speaks only when the price moves; hippo records the trigger as a
routine, not as their words.

Photos, PDFs and text files sent to Sokka are decrypted, typed by their
first bytes rather than the sender's word, and handed to the model with
the message. They are read once and kept nowhere: hippo holds only text, so
the prompt asks the answer to state what matters in the file (dates,
amounts, names), and that answer is what Sokka remembers.

The module runs one instance per person, each with its own Matrix account,
hippo store, book and chat, so no instance can read another's memory.
They share the calendar login and the model; mail and alerts are set per
instance, and only one instance may take the alerts. Dylan's is Sokka, with
his mail and the alerts; Gab's is Suki, with neither.

What crosses between instances goes through one household directory that
only their shared group can write. It holds the shared lists, a book like
each instance's own, and a mailbox per instance. A list is personal until it
is made shared or shared later, and the others are told when that happens.
"Tell Gab ..." leaves a message in Suki's mailbox, which her bot drains on
its 30-second tick the way Sokka drains alerts: it passes the message on in
its own words and keeps it as a note. A shared routine runs once, on its
owner's instance, and the bot drops the answer in the others' mailboxes too,
so one assistant curates and the rest relay. Memories never mix; only what
is handed over crosses.

Sokka answers only the users it is configured for, joins
only their rooms, and runs as its own fenced user with loopback and the
internet but not the tailnet or the LAN. Chats are end-to-end encrypted
(matrix-sdk): the bot holds its own cross-signed device, so neither the
homeserver nor the Cloudflare tunnel in front of it sees the text.

## Homelab

Water runs the house's services as one bundle, `lab`. Which services they
are matters less than how they are put together.

**One front door.** nginx terminates TLS for every `<service>.su.is` with a
single wildcard certificate, issued by DNS-01 because the host is not
publicly reachable. Each service module declares its own route (subdomain
and port) beside its config, and the dashboard is generated from the same
routes, so adding a service touches one file. The names resolve publicly
but route only inside the tailnet, and an explicit default vhost catches any
name with no route.

**One message bus.** A private Matrix server, with federation off, carries
everything that talks to people: alarms, the fleet's audit log and the
household bot.

**Fenced by default.** Each service gets a network fence and only the paths
its job needs, even where a shared group would allow more. Software that
ships no isolation of its own takes the `vendor` preset; the alert sensors
run as `rootSensor`.

### NAS and backups

Water's NAS is an encrypted Btrfs filesystem on a 4 TB SSD, backed up to an
encrypted Restic repository on an 8 TB HDD (`modules/homelab/nas`).

Setup is a script, not an activation. `prepare-water-nas` checks the exact
drive serials and sizes, formats only those, and leaves a marker so it can
never run twice. Bind mounts keep every service's original paths, so moving
data onto the NAS changed no service configuration. A recovery bundle (key,
LUKS header, backup password, commands) is written for off-machine storage.

Each night at 03:30 the backup pauses only the Immich server, dumps its
PostgreSQL database, takes a read-only Btrfs snapshot and resumes Immich.
Restic copies the snapshot to the HDD, then proves the copy: it restores a
probe file and the full database dump from the repository, compares bytes,
and parses the dump. On Sundays it prunes old snapshots and reads back 5% of
the stored data. Details are in `modules/homelab/nas/README.md`.

### Alerts

Every alarm becomes a message in Sokka's chat. Four sensors feed it: a
global `OnFailure` drop-in on every systemd unit, a six-hourly sweep for
conditions `OnFailure` cannot see, smartd, and the UPS monitor's spool.
Each writes through `ship-alert`, a short shell script that drops repeats
and renames one file per alert into a spool only root and Sokka can write.
On its 30-second tick Sokka hands the pending files to the model as one
request and sends the answer, an admin's read of what happened, whether it
needs Dylan and what to do, and deletes them only once that is sent, so
alerts wait out a homeserver outage. If the model fails, the alerts go out
word for word instead.
Air has no Sokka: a relay hands each alert over the tailnet to a socket on
Water that admits only Air's address, and deletes it once Water answers.
