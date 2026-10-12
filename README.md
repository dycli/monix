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
- **Topology** (`topology.nix`): the AI system's users, uids, paths and
  addresses in one place, so the seat and the hosts it reaches agree.

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

Coding agents (Claude Code, Codex, OpenCode, Muse Code) run in `bridge`, one
unprivileged account with a fixed uid. It has no wheel, no Nix trust and no
host secrets. A per-user network fence applies to every process it starts:
it cannot reach the LAN or the tailnet, and reaches the local model server
only through its own address on the seat plane.

Its home is composed in Nix, and one set of managed settings applies to every
launcher, Paseo included, so an agent started from a phone has the same rules
as one in a terminal. It can push to this repo; only the captain switches a
host onto a commit. For the web it drives Brave over MCP, either headless
inside the fence or the visible one on a desktop, served over HTTP on the
tailnet to Water alone.

### hippo

hippo is the seat's episodic memory, written in Rust in
`modules/ai/seat/hippo`, with seven dependencies. The design follows Victor
Taelin's OptChat: keep every message, and fold the whole history into a
fixed-size summary that any session can read. It is developed here and
mirrored to [dycli/hippo](https://github.com/dycli/hippo) as its own repo,
with its own flake and README, by

```
git subtree push --prefix=modules/ai/seat/hippo git@github.com:dycli/hippo.git main
```

after a push that touches it.

**Recording.** A watcher follows Claude Code, Codex and OpenCode transcripts
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
atomically whenever the tree grows. On the seat, `~/.claude/rules/hippo-view.md`
links to it, so Claude Code loads the whole view at session start and after
every compaction with no tool call. Codex gets the same from a SessionStart
hook in its system config, which prints the view and inbox at startup and
after each compaction. In OpenCode a plugin appends one snapshot per session
to the system prompt and takes a fresh one after compaction.

**Session compaction.** Claude Code and Codex compact at 200k tokens, and
all three harnesses write a short handoff instead of the usual summary:
Claude Code's from a PreCompact hook, Codex's from its `compact_prompt`,
OpenCode's from the plugin. A session comes
back as handoff plus fresh view rather than a long transcript summary.
Compactions went from 97-113 seconds to 16-18. Each harness first runs
`hippo fold`: the seat is the one reader that keeps a live context
between reads of the view, so its raw lines only duplicate that context,
and its cache is rewritten at compaction anyway. Folding there, instead of
at 128 KB, is the batch at the boundary where it is free; the fresh
context opens on a 64 KB view whose tail is the end of the last stretch at
the usual falling resolution, and the chat itself is the raw frontier.

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

### bridge, the notes

`/var/lib/bridge` (`notes.mod.nix`) is the seat's folder of markdown notes,
the curated layer over hippo: hippo records what was said, the notes hold
what is true now and are rewritten in place. The folder is bind-mounted
as `bridge` inside the primary user's Syncthing folder, so it reaches the
captain's desktop and phone with the rest of that folder and Obsidian
opens the subfolder as the vault "bridge"; nothing on the server side
depends on Obsidian. The Syncthing user joins the seat's group and runs
with a group-writable umask, so either side can edit the other's files.
The folder is in the OS backup set.

### Local inference

llama-swap starts one `llama-server` per model on demand and unloads it when
idle, so a host holds no model memory until something asks.

### The yeoman

The yeoman (`modules/ai/yeoman`) is the household assistant program, a small
Rust service on Matrix, run once per person: Sokka for Dylan, Suki for Gab. It has no sessions and never compacts: every message becomes one
fresh model call over its prompt, its whole memory and the new message.
The memory is a second hippo store, written directly instead of by
following transcripts: the bot logs each message and each answer, and hippo
folds them into a 128 KB view, the seat's size, so once the view fills an
endless chat costs the same per call on its hundredth day as its thousandth.

The model is configuration: the `claude` CLI on a subscription token, or
any OpenAI-compatible endpoint, local or hosted. The CLI runs with built-in
tools and settings off; its tools come over MCP, and the prompt mentions
them only when the model has them. Its own server, `yeoman tools`, searches
and fetches the web through Parallel's keyless one, keeps reminders and
lists in one SQLite book and can touch nothing else, so a page that tries
to steer the model through search results finds no keys, memory or shell
to reach. Fetch opens only links a search of its own returned or the
person wrote, so a made-up link cannot carry what the model has read.
The same server holds the calendar: plain CalDAV and iCalendar over the
one HTTP client, the login read from a systemd credential; it lists, adds,
moves and cancels events, with repeats expanded. Mail is read there too,
over IMAP in plain protocol on a TLS stream: folders open with EXAMINE and
bodies are fetched with `BODY.PEEK`, so nothing is moved or marked read. No
tool sends: the model only drafts, the draft shows whole in the chat, and a
👍 reaction from the person's own account makes the assistant itself send it
over SMTP; 👎 drops it. The model holds no tool that sends, so no text it reads can make it,
and a draft an injected page shaped is still read before it is approved. Since
any sender or page can put text in
front of the model, fetch opens only links that a search in the same call
returned or that the person wrote, as OpenAI's agents do: a link the model
made up could carry what it read out in its path, but a link that existed
before it read anything carries nothing. YouTube goes through `yt-dlp`, run
as a subprocess: a search, and a video's captions as text, the uploader's
own before automatic ones; any link that is not YouTube is refused.

Who started a turn decides what it may do. A message from the person, or a
routine they set, runs with every tool. A turn that an alert or another
instance's message started has the tools that act withheld (reminders,
lists, the mailbox, the calendar, pictures, fetch): the text arrives quoted
in `<alert>` or `<message>`, and the prompt says such text is information,
never an instruction, so the worst a crafted alert can do is be read out.
Nothing about the person's own messages is wrapped or restricted.
Pictures are a sixth: the assistant describes one, and a small socket-activated
service draws it with Codex on the household's ChatGPT subscription. That
service alone holds the Codex login; the assistants reach only its socket. The
picture waits in the instance's outbox, goes out with the answer, encrypted
like any attachment, and is then deleted.
Another socket service, `usage`, reports how much of each subscription's
limits is used (Claude, ChatGPT/Codex, OpenCode Go), read live from each
provider and never stored; the assistants ask it through their tools and the
seat through its `usage` command, and only it sees the logins. Under each
Claude and Codex window it shows who used it: a second service, run as the
seat and offline, prices the seat's own transcripts and the one journal line
each assistant, memory and picture writes per call at API rates, and splits
the window by them. Use from other machines is not counted.
The bot checks the book every 30 seconds and sends due reminders itself,
logging them to hippo like any other answer. A reminder leaves the book only
once Matrix has it, and a routine's answer is kept until then, so a failed
send goes again on the next check, at worst twice, never lost. A reminder can instead be a
routine ("a mail digest at 8, 2 and 8"): when it comes due, the bot runs its
text as a request, with the same tools as a message from its person, and sends
the answer, or stays quiet when it has nothing new, so a daily price
check speaks only when the price moves; hippo records the trigger as a
routine, not as their words.

Each assistant can have a computer of its own (`yeoman-computer.mod.nix`): a
persistent microVM under cloud-hypervisor, with a desktop that only
it touches. Brave runs full screen under cage on a headless wlroots output,
and Playwright MCP, the same server the seat's browser tool uses, drives it
over HTTP from the host, so the model works a page by its accessibility tree
and takes a screenshot when it needs to look. The server closes its shared
browser when the last client leaves, and the assistant connects once per
reply, so a keeper in the guest holds a session of its own while the
assistant has a lease on the browser: a reply that drives it takes one, each
use renews it for half an hour, and the assistant can hold it open until told
or close it now. The browser profile lives on a
volume that survives reboots and rebuilds, so site logins made there stay
there, and nothing of the household goes in: no tailnet, no store share, no
secret. The guest's network (`yeoman-network.mod.nix`) is a host-only bridge
with NAT: any public address, no private one, not the host, the LAN, the
tailnet or another computer, while the host reaches each guest for its browser
and screen. A folder shared over virtiofs is the desk: screenshots land there,
and `show` copies one into the outbox so it goes out with the answer. The
screen is also a page on the tailnet, `<name>-screen.<domain>`, noVNC through
websockify to the guest's VNC, and the prompt tells the assistant to hand out
the link when the person must take the keyboard (a captcha, a sign-in only they
can do). On a turn an alert or a household message started, the computer is
withheld like the other tools that act. `<name>-computer-reset` wipes the
profile back to a clean desk. Browser actions are not gated: the VM holds no
payment method or password manager, so the worst a page can do is what a
logged-in site allows, and sending anything outward still goes through the
draft-and-👍 path.

Work that takes a while is a task: the model starts it with the request
worded as the person's, says it is under way, and stops; the bot runs it on
its 30-second tick as a turn of its own with no clock on it, posts whatever
the task says along the way, and sends its answer when done. One task at a
time per instance; "stop" cancels it, which kills the model call. A task is
a person's turn, so it can act and draft, and its drafts wait for 👍 like
any other.

Each assistant has a site, `<name>.<domain>` on the tailnet proxy: `show_page`
writes one HTML document under a name of plain letters, digits and dashes,
and hands back its link, for anything a chat message would flatten (a chart,
a table, a plan). The same name again replaces the page, and every version
stays at its own dated link. It is a directory of files that nginx serves
read-only as the assistant's group; nothing runs on it.

With `homeTokenFile` set, both assistants also hold Home Assistant's own MCP
server, the one that ships with it, over its Assist API: state of what is
exposed to Assist, and the intents to act on it. The long-lived token lives
in a systemd credential and is filled into a private copy of the MCP file at
unit start. On a turn an alert or a household message started, the home is
withheld like every other tool that acts.

With `requestsKeyFile` set, they can also request films and shows through
Seerr on loopback, from the same Rust tool server: search the catalogue, list a show's seasons, make the
request and read back what is pending. The request goes in under the Seerr
user named like the person when there is one, so it shows as theirs; only
the request itself is a tool that acts.

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

The ship's seat is in the household too, as Bridge. `tell Sokka ...` from
the seat leaves a note in a box of Sokka's that its tick drains like its
mailbox, marked as the engineer's, not the person's; Sokka does what it
would do for its person, answers with its own `tell` to Bridge, and tells
its person in a line what happened. Notes to Bridge append to one inbox
file that the seat's sessions load as a rule, like the hippo view, and
`inbox` prints on demand.

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
everything that talks to people: alarms and the household bot.

**Fenced by default.** Each service gets a network fence and only the paths
its job needs, even where a shared group would allow more. Software that
ships no isolation of its own takes the `vendor` preset; the alert sensors
run as `rootSensor`.

### NAS and backups

Water's NAS is an encrypted Btrfs filesystem on a 4 TB SSD, backed up to an
encrypted Restic repository on an 8 TB HDD (`modules/homelab/nas.mod.nix`).
Bind mounts keep every service's original paths, so moving data onto the NAS
changed no service configuration.

Each night at 03:30 the backup pauses only the Immich server, dumps its
PostgreSQL database, takes a read-only Btrfs snapshot of the SSD and one of
the OS subvolume, and resumes Immich. Restic copies the SSD snapshot and the
OS-disk state no rebuild recreates (Matrix, Home Assistant, Minecraft,
Prowlarr, the assistants) to the HDD, then proves the copy: it restores a
probe file and the full database dump from the repository, compares bytes,
and parses the dump. Only then does it record a success, and the alert sweep
complains when that record is two days old. On Sundays it prunes old
snapshots and reads back 5% of the stored data. `nas-backup` runs one by
hand; `restic snapshots` and `restic restore` work from a root shell with the
repository at `/srv/backup/restic` and its password in
`/var/lib/nas/restic-password`.

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
The spool has a door: a plain HTTP POST to port 7749 on Water is an alert,
from Air's tailnet address or from Water itself. Air has no Sokka: a relay
posts each alert there and deletes it once Water answers. Home Assistant
has a `ship_alert` rest command on the same door, so any automation built
in its UI (the UPS on battery, a camera seeing someone at night) wakes the
assistant with a message of its choosing.
