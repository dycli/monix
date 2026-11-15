# Plan: macOS hosts in monix through nix-darwin

Status: layer 1 is built on branch `metal` (§8), with layer 2's host
config ready for the first switch (§6). Layers 3 to 5 are planned. Dylan's
answers (2026-11-14) are recorded in place, and the open questions that
remain are the machine-wide settings (§9).

**metal is shared.** A second person has her own macOS account on it, and
nothing here may change her side. Per-user state goes to Dylan's account
only: Home Manager, `system.defaults` user domains (which nix-darwin writes
for `system.primaryUser` alone), and launch agents in his
`~/Library/LaunchAgents`. Everything that is unavoidably machine-wide is
listed in §9 with its effect on her account.

Host name: **metal** (Dylan, 2026-11-14). It replaces the device now on the
tailnet as `gabs-mac-dylan` (100.103.37.115). Hardware: MacBook Air M5,
24 GB, 1 TB, macOS Tahoe. Dylan's macOS short name is `dylan`; the official
Nix installer is in, and Remote Login is on (OpenSSH 10.5).

Sources:

- RGBCube/ncc at a49f25d, cited as `ncc:path:line`.
- monix at main 35aad56, cited as `path:line`.
- nix-darwin master at ff0e21a (2026-10-31), cited as `nix-darwin:path:line`.

## Summary

- **One new input and one new host constructor.** `nix-darwin` is added as an
  input. `lib.ship.darwinHost` sits beside `lib.ship.host` and builds
  `darwinConfigurations.metal`.
- **Shared modules without duplication.** One new collection,
  `flake.commonModules`, holds the modules that work on both platforms. It is
  mirrored into both `nixosModules` and `darwinModules`, the way ncc does it and
  the way monix already mirrors `homeModules`.
  - Modules that are only partly portable split by aspect inside their own file:
    a common part, a NixOS part and a Darwin part.
  - No pipe-heavy library, no flake-parts override and no custom bootstrap.
- **switcharoo stays one module and one script, branching on the platform.**
  The deploy sequence becomes:
  1. Build.
  2. Activate.
  3. Judge health: launchd jobs, sshd, tailscaled and the tailnet.
  4. If unhealthy, reactivate the previous system.
  5. If healthy, set the system profile. On macOS that profile is the boot
     default, because `activate-system` reloads it at boot.
  - The fence and `--approve` are unchanged.
  - The password-free trigger on macOS is a sudoers rule that names one exact
    command.
- **Apps go three ways:**
  - Command-line tools come from nixpkgs.
  - GUI apps, Brave included, are Homebrew casks through nix-homebrew.
  - Xcode comes from the App Store through `homebrew.masApps`.
  - Casks install into Dylan's `~/Applications`. Homebrew never removes an
    app the config does not list, so nothing the other account installed is
    touched (§9).
- **Desktop: effectively no Dock, no tiling window manager, and a few global
  keys that open apps.** Hammerspoon, a cask with a Nix-written `init.lua`
  as in ncc, binds Option with Hyprland's letters: Enter opens Ghostty, W
  opens Brave, Q quits the front app, I toggles the idle inhibitor (§4).
- **Hex dictation on Caps Lock, as on Linux.** Hex comes from its vendor's
  cask (`anomalyco/tap/hex`), since its flake builds only for Linux. Caps
  Lock goes to Hex without a system-wide remap if Hex's Labs Caps Lock
  dictation holds up; the `hidutil` remap to F18 changes the key for every
  account, so it is Dylan's choice (§4, §9).
- **The Rust toolchain stays in Libri, not on the host.** Libri's flake already
  carries rust-overlay for Android. The iOS targets join it as a devShell, so
  metal needs only Xcode, Nix and direnv.

## 1. What ncc does, and what monix takes from it

### Flake and host constructor

- ncc builds Darwin hosts with `systems.darwinSystem` (`ncc:lib/systems.nix:3-21`).
  - It calls `inputs.nix-darwin.lib.darwinSystem` with `lib = self`, so ncc's
    extended lib reaches every module.
  - It imports `darwinModules.default`, then the host module, then sets the
    hostname.
  - It mirrors `systems.nixosSystem` (`ncc:lib/systems.nix:23-35`).
  - nix-darwin accepts a `lib` argument: `darwinSystem` passes any `lib` it is
    given through to `evalConfig` (`nix-darwin:flake.nix:21-24`).
- The Mac host is `ncc:hosts/pala.mod.nix`. It imports four darwin bundles and
  sets:
  - `system.primaryUser`.
  - `users.users.pala.home = "/Users/pala"`.
  - `nixpkgs.hostPlatform = "aarch64-darwin"`.
  - `system.stateVersion`.
  - The network services nix-darwin may manage.
- monix's `lib.ship.host` (`lib/default.nix:68-81`) has the same shape as ncc's
  constructor, so a Darwin twin is a direct copy.

### Shared and per-platform modules

- ncc declares `options.commonModules`, "Modules shared between NixOS and
  Darwin", and merges it into both `flake.nixosModules` and
  `flake.darwinModules` (`ncc:options/flake-outputs.mod.nix:85-101`).
  `homeModules` are mirrored into both the same way.
- A partly portable concern sets `commonModules.X` plus `nixosModules.X` and
  `darwinModules.X` in one file. Two examples:
  - `ncc:modules/nix.mod.nix:3-82` is shared. The NixOS part sets `gc.dates`
    (`:84-97`). The Darwin part sets `gc.interval` (`:99-111`).
  - `ncc:modules/secrets.mod.nix` aliases `secrets` in common (`:3-11`). Each
    platform imports its own agenix module (`:13-62`).
- `ncc:modules/groups.mod.nix:10-14` builds `darwinModules.default` from the
  `desktop`, `networking` and `shell` bundles. Monix's rule is that a host lists
  its layers (AGENTS.md, Bundles), so monix does not adopt a groups file.

### Darwin desktop, Homebrew and apps

- `ncc:modules/darwin-desktop.mod.nix` holds the Dock, menu bar, screenshot and
  trackpad defaults (`:12-82`). It joins `darwinModules.desktop` (`:3`).
- `ncc:modules/darwin-unshittify.mod.nix` sets the login window, the
  screensaver password, local saves by default, quarantine off, macOS updates
  off and ad tracking off (`:6-33`).
- `ncc:modules/homebrew.mod.nix:4-23` sets up Homebrew:
  - It imports `nix-homebrew` and sets `homebrew.enable`.
  - It pins the `homebrew-core` and `homebrew-cask` taps to flake inputs
    (`ncc:flake.nix:74-84`), with `mutableTaps = false`.
  - The result is that Homebrew itself and its formula and cask definitions are
    locked by `flake.lock`.
- Apps are casks next to their concern, for example `homebrew.casks =
  singleton "signal"` in `ncc:modules/communication.mod.nix:73`. ncc sets no
  `onActivation.cleanup`, so apps it drops stay installed.

### Nix and Determinate

- ncc does not use Determinate Nix. nix-darwin manages Nix:
  - `nix.package = pkgs.nixVersions.latest` (`ncc:modules/nix.mod.nix:34`).
  - The flake's `nixConfig` becomes `nix.settings`, minus `use-cgroups` on
    Darwin (`:36-38`).
  - The only `nix.enable = false` in ncc is a throwaway evaluation for option
    types (`ncc:options/entities.mod.nix:106`).
- nix-darwin's README recommends the Lix installer for its uninstaller. It says
  that whichever installer is used, nix-darwin then manages Nix itself
  (`nix-darwin:README.md:16-18`).
- **monix uses the official installer** (Dylan, 2026-11-14), so metal runs the
  same Nix as the Linux hosts. They set no `nix.package`, and nix-darwin's
  default is the same `pkgs.nix` (2.35.6 at the current lock). nix-darwin
  recognises the official installer's `/etc/nix/nix.conf` and shell files by
  hash and moves them aside itself at the first switch.
- Determinate Nix would need `nix.enable = false`. That leaves `nix.settings`
  unmanaged, including `pipe-operators`, the substituters and the trusted keys
  monix sets (`modules/core/nix.mod.nix:16-40`). So monix does not use
  Determinate.

### Deploys and secrets

- ncc deploys with one push-style `deploy` package
  (`ncc:packages/deploy-and-rollback/deploy.mod.nix`):
  - It picks the platform from the configuration's class (`:13-22`).
  - The activation command is `switch-to-configuration switch` on NixOS and
    `$toplevel/activate` on Darwin (`:37-40`).
  - It sets the system profile and then activates (`:44-46`).
  - Rollback lists `system-N` generations and activates the chosen one
    (`:73-109`).
  - There is no health check and no automatic rollback.
- The switcharoo design below keeps monix's pull-and-judge model and takes only
  ncc's per-class branch.
- Secrets on Darwin import `agenix.darwinModules.age`, with the identity at
  `~/.ssh/id` (`ncc:modules/secrets.mod.nix:52-62`). ncc's own FIXME marks that
  path as a workaround.
  - monix decrypts with the SSH host key (`modules/core/secrets.mod.nix:13`).
  - macOS keeps its host key at the same `/etc/ssh/ssh_host_ed25519_key` once
    Remote Login is on, so monix's choice carries over unchanged.
- ncc's sudo on Darwin enables Touch ID for sudo (`ncc:modules/sudo.mod.nix:27-40`).

### The nix-darwin pin to pull/1765

- ncc earlier pinned nix-darwin to its own fork branch,
  `master-with-modular-services`. Commit 76e195e (2026-07-29) replaced the fork
  with `github:nix-darwin/nix-darwin?ref=pull/1765/merge`.
- So the PR is the modular-services integration for nix-darwin: the
  `system.services.<name>` option backed by launchd.
- ncc uses it on Darwin for its resolver and its ssh-agent
  (`ncc:modules/dns.mod.nix:371`, `ncc:modules/ssh.mod.nix:179,212`).
- **monix does not need it.** No monix module uses `system.services`. metal
  pins `nix-darwin/nix-darwin` master and follows nixpkgs.
- Verification is limited: GitHub refused a direct page fetch, so the PR's
  current merge state was not checked. The finding rests on that commit and on
  ncc's use of `system.services`.

## 2. monix today

### Structure

- Module discovery picks up every `*.mod.nix` (`flake.nix:154-156`).
- `options/flake-outputs.mod.nix:136-170` keys the collections and mirrors each
  `homeModules` attribute into the NixOS attribute of the same name, applied to
  the primary user.
- monix has **no `commonModules` today.** "Every host" means
  `nixosModules.default`, and much of it is NixOS-only.
- Checks build every NixOS host on x86_64-linux only (`options/checks.mod.nix:8,53-58`).

### Portability of what a host would import (`default` and `dev`)

| Module | Verdict | Why |
|---|---|---|
| `options/host.mod.nix` (`primaryUser`, `unfreePackages`) | portable | option declarations only; `kestrel.*` is inert off Hyprland |
| `core/nix.mod.nix` | split | `nix.settings`, registry, channel, optimise and `allowUnfreePredicate` are shared; `nix.gc.dates` (`:55`) is NixOS (Darwin uses `gc.interval`, as `ncc:modules/nix.mod.nix:106`) |
| `core/binary-cache.mod.nix` | split | the substituter (`:41-45`) is shared; `services.harmonia` (`:33`) is NixOS-only. Defining it fails on Darwin even under `mkIf`. Water's cache holds no darwin builds, so on metal it serves sources at most |
| `core/secrets.mod.nix` | split | the alias and identity are shared; the platform agenix module is imported per platform |
| `core/pki.mod.nix` | NixOS-only | nix-darwin's own `security.pki` default already blacklists the same "Comodo AAA Services root" (`nix-darwin:modules/security/pki/default.nix:78`), so metal needs no line |
| `core/home.mod.nix` | split | `home-manager.nixosModules` (`:14`) and a hard-coded `/home/…` (`:22`); derive the home from `users.users.<primary>.home` and import `darwinModules.home-manager` per platform |
| `core/users.mod.nix` (fenced) | split | `mutableUsers`, `isNormalUser` and `wheel` (`:10-17`) are NixOS; Darwin sets `home` and `openssh.authorizedKeys.keys` (`nix-darwin:modules/programs/ssh.nix:69-107`) |
| `core/switcharoo.mod.nix` (fenced) | split | see §5 |
| `core/locale.mod.nix` | NixOS-only | `time.timeZone` exists on Darwin (`nix-darwin:modules/time/default.nix:11`), but it runs `systemsetup` and sets the zone for every account, so metal keeps the zone macOS has |
| `core/boot`, `disko`, `journald` | NixOS-only | |
| `networking/ssh.mod.nix` (fenced) | split | `openFirewall` and `settings` are NixOS; Darwin uses `services.openssh.enable` and `extraConfig` (`nix-darwin:modules/services/openssh.nix:74-121`) |
| `networking/tailscale.mod.nix` | split | `useRoutingFeatures`, `extraSetFlags` and the firewall are NixOS; nix-darwin's `services.tailscale` has `package` and `overrideLocalDns` only (`nix-darwin:modules/services/tailscale.nix:18-64`) |
| `networking/networking`, `resolver`, `syncthing` | NixOS-only | |
| `packages.mod.nix` system list | split | everything but `strace` (`:39`) builds on Darwin; `environment.defaultPackages` and `programs.nano` (`:15-16`) are NixOS options |
| `ai/agent-clis.mod.nix` | portable | an overlay keyed by `hostPlatform.system` |
| `cli/ghostty.mod.nix` | split | terminfo is portable; the home config carries a systemd `onChange` (`:29`) and Hyprland-specific settings (`:46`, keybinds) |
| home `git`, `direnv`, `btop`, `lf`, `nushell` | portable | home-manager only; nushell reads `osConfig.networking.hostName`, which Darwin sets |
| home `editors` (`dev`) | portable | |
| home `packages-dev-extras` (`dev`) | split | `gcc` would shadow Apple clang, which Xcode builds rely on; the rest is portable |
| `desktop`, `hyprland`, `lab`, `seat`, `web` bundles | NixOS-only | |

## 3. Flake shape

### Inputs

Add these inputs. Each one is a separate step: `nix-darwin` in layer 1,
`nix-homebrew` and the taps in layer 4.

```nix
inputs.nix-darwin = {
  url = "github:nix-darwin/nix-darwin";
  inputs.nixpkgs.follows = "nixpkgs";
};

inputs.nix-homebrew.url = "github:zhaofengli/nix-homebrew";

# Homebrew's own definitions, locked like any input so a switch installs
# what the lock names.
inputs.homebrew-core = { url = "github:homebrew/homebrew-core"; flake = false; };
inputs.homebrew-cask = { url = "github:homebrew/homebrew-cask"; flake = false; };
inputs.homebrew-anomalyco = { url = "github:anomalyco/homebrew-tap"; flake = false; };
```

nix-darwin master matches nixpkgs-unstable. Its release check
(`nix-darwin:eval-config.nix:1-14`) compares the two.

### Host constructor

`lib.ship.darwinHost` goes in `lib/default.nix`, next to `host`:

```nix
darwinHost =
  hostName: module:
  { inputs, ... }:
  {
    flake.darwinConfigurations.${hostName} = inputs.nix-darwin.lib.darwinSystem {
      lib = final;
      modules = [
        inputs.self.darwinModules.default
        module
        { networking.hostName = hostName; }
      ];
    };
  };
```

### Collections

`options/flake-outputs.mod.nix` changes:

- Add `flake.darwinModules`, keyed and wrapped like `nixosModules` (`:148-153`).
  This keeps the deduplication guarantee.
- Add `commonModules`: "Aspects that hold on NixOS and on Darwin alike". It is
  wrapped the same way and merged into both `flake.nixosModules` and
  `flake.darwinModules`, as `ncc:options/flake-outputs.mod.nix:85-101` does.
- Mirror `homeModules` into `darwinModules` as well as `nixosModules`.
  home-manager's option path is the same on both platforms.

A file never registers the same aspect name in both `commonModules` and a
platform collection, because the merged attribute would collide. The common
part keeps the concern's name (`nix`), and the platform parts add the platform
(`nix-linux`, `nix-darwin`). For example, `modules/core/nix.mod.nix` becomes:

```nix
commonModules.default = self.commonModules.nix;
commonModules.nix = { … nix.settings, registry, channel, optimise, gc.automatic, gc.options … };

flake.nixosModules.default = self.nixosModules.nix-linux;
flake.nixosModules.nix-linux.nix.gc.dates = "weekly";

flake.darwinModules.default = self.darwinModules.nix-darwin;
flake.darwinModules.nix-darwin.nix.gc.interval = { Weekday = 1; Hour = 0; Minute = 0; };
```

The same split is applied to each "split" row in §2. Bundles keep their names;
`desktop` on Darwin is a new set of members, not a new bundle name. AGENTS.md
gains `darwinModules` and `commonModules` under "Module shape", and a
`darwinHost` line under "Hosts".

### Checks

**Water can evaluate metal but cannot build it.** A toplevel for
aarch64-darwin needs a Darwin builder; Linux cannot build or cross-compile to
macOS. So the orders' "built on Water" becomes:

- `checks.x86_64-linux.eval-metal`: a `writeText` that records
  `darwinConfigurations.metal.config.system.build.toplevel.drvPath`, its
  string context dropped so the check does not depend on the Darwin build
  itself. Evaluating
  the check forces the whole configuration, so `ship-check` catches every
  evaluation error, option collision and missing option on Water.
- The real build happens on metal, in its own switcharoo.
- A later, optional step: Water's Nix could list metal as a remote builder for
  aarch64-darwin. Then Water would build and cache metal's systems. That needs
  metal's Nix to trust Water's key, so it is deferred.

## 4. The host file

`hosts/metal/metal.mod.nix`, as built in layer 1:

```nix
# metal — a MacBook Air (Apple silicon) shared with a second macOS account,
# whose side nothing here may change: per-user settings go to the primary
# user only, and each machine-wide one is listed in docs/darwin-plan.md.
{ lib, ... }:
{
  imports = lib.lists.singleton (
    lib.ship.darwinHost "metal" (
      { config, ... }:
      {
        # The macOS short name, as `whoami` prints it on the Mac.
        primaryUser = "dylan";
        nixpkgs.hostPlatform = "aarch64-darwin";
        system.stateVersion = 7;
        home-manager.users.${config.primaryUser}.home.stateVersion = "26.11";
      }
    )
  );
}
```

`system.primaryUser` and the home directory come from the Darwin part of
`users.mod.nix`. Layer 4 adds the imports `self.darwinModules.desktop`,
`self.darwinModules.dev` and `self.darwinModules.apple-build`.

`system.stateVersion = 7` is nix-darwin's current maximum
(`nix-darwin:modules/system/version.nix:51-55`). The concerns the host pulls
in, by module:

| Concern | Where | What |
|---|---|---|
| SSH with Water's key | `users.mod.nix` (Darwin part), `ssh.mod.nix` (Darwin part) | `services.openssh.enable = true` keeps Remote Login on (it is already on, so nix-darwin leaves it alone; `nix-darwin:modules/services/openssh.nix:112-121`); `extraConfig` turns password and keyboard-interactive login off, refuses root and sets `AllowUsers dylan`; the primary user's keys are `keys.admin` plus `keys.seat` (`bridge@fw0`, added to `keys.nix`). nix-darwin serves them from `/etc/ssh/nix_authorized_keys.d/dylan` through `AuthorizedKeysCommand`, so no account file changes |
| Tailscale | `tailscale.mod.nix` (Darwin part) | `services.tailscale.enable = true`: the open-source `tailscaled` as a launchd daemon (`nix-darwin:modules/services/tailscale.nix:54-57`), which runs before anyone logs in. It replaces the GUI app now installed (§6) |
| Stay awake on power | `apple-build.mod.nix` | `pmset -c sleep 0` in the `postActivation` script (built); display sleep keeps macOS's own setting. `power.sleep.computer` uses `systemsetup`, which applies on battery too (`nix-darwin:modules/power/sleep.nix:60-63`), and this is also a laptop. Power settings are machine-wide (§9). The lid stays open (Dylan) |
| Xcode | `apple-build.mod.nix` | `homebrew.masApps.Xcode = 497799835`; an activation step runs `xcode-select -s /Applications/Xcode.app` and checks the licence with `xcodebuild -checkFirstLaunchStatus` (it reports; it does not accept) |
| xcodegen | Libri's iOS devShell | nixpkgs `xcodegen` builds for aarch64-darwin |
| Rust with iOS targets | Libri's iOS devShell | rust-overlay with `aarch64-apple-ios` and `aarch64-apple-ios-sim`, beside the Android shell (`libri:flake.nix:13-14,330-333`). The toolchain is versioned with the code it builds, and the host stays unchanged when Libri changes Rust |
| Shell, git, editors | existing home modules (§2) | nushell, git and gh, direnv, NvChad, unchanged. Dylan's `~/.zshrc` (Home Manager) loads nix-darwin's environment and enters nushell. nix-darwin's own `/etc/zshrc` and `/etc/bashrc` are off (`programs.zsh.enable = false`), so the other account's shell and prompt stay macOS's |
| Tools | `packages.mod.nix`, `nix.mod.nix` (Darwin parts) | the universal tool list, `nh` and `nix-output-monitor` go to Dylan's Home Manager profile, not `environment.systemPackages`, so they are not on the other account's `PATH` |
| Nix | `nix.mod.nix` common part | the same settings as the NixOS hosts; `pipe-operators` is on after the first switch |
| macOS defaults | `darwin-desktop.mod.nix` | below |

`apple-build` is a new bundle for the iOS and macOS build role: Xcode, its
selection and staying awake. It has a real member and a real importer, so it
meets the AGENTS.md rule.

### Apps (answering Dylan's question)

Yes: metal manages everyday apps, not only build tools. Each kind of app takes
one route:

| Kind | Route | Why |
|---|---|---|
| Command-line tools | nixpkgs (`home.packages`, the system list) | locked, the same versions as the Linux hosts |
| GUI apps | Homebrew casks through nix-homebrew | signed vendor builds in Dylan's `~/Applications` (`homebrew.caskArgs.appdir = "~/Applications"`), updated by their vendors; nixpkgs GUI builds land in `/Applications/Nix Apps` and many are Linux-only |
| App Store apps | `homebrew.masApps` | the only route for App Store-only apps such as Xcode |

**Worked example: Brave.**

- Brave is a cask: `homebrew.casks = [ "brave-browser" ]`. On metal that line
  goes in `modules/desktop/brave/brave.mod.nix` as
  `darwinModules.desktop = self.darwinModules.brave-cask`, the same concern
  file as Brave's Linux policies.
- nixpkgs is not an option for Brave: it left nixpkgs on 2026-11-03, and monix
  builds it from Brave's `.deb` for Linux (`modules/desktop/brave/brave.mod.nix:24-26`).
- Brave updates itself. Brave's policies can follow later through
  `system.defaults.CustomUserPreferences."com.brave.Browser"`.

**Defaults, kept minimal:**

- `homebrew.onActivation.cleanup = "none"`, nix-darwin's default. Homebrew's
  prefix (`/opt/homebrew`) is one per machine, and `"uninstall"` and `"zap"`
  remove every formula and cask the Brewfile does not list
  (`nix-darwin:modules/homebrew.nix:78-111`), the other account's included.
  `"check"` would fail every switch while she has one of her own. So:
  - Her drag-installed (DMG) apps are never seen by Homebrew.
  - Her App Store apps are not removed: `brew bundle --cleanup` does not
    uninstall `mas` apps.
  - Her own Homebrew formulae and casks, if she has any, stay.
  - The cost: a cask removed from the config stays installed, and Dylan runs
    `brew uninstall --cask <name>` once by hand.
  - Before layer 4, `ls -ld /opt/homebrew` on metal shows whether Homebrew is
    already there and whose it is. nix-homebrew refuses an existing prefix
    unless `nix-homebrew.autoMigrate = true`, which takes it over; that
    matters if it is hers.
- `homebrew.caskArgs.appdir = "~/Applications"`, so casks land in Dylan's
  `~/Applications` and not in her Launchpad or Spotlight. Casks that ship a
  `.pkg` installer, and App Store apps (Xcode), still install into
  `/Applications`, for every account (§9).
- `homebrew.onActivation.autoUpdate = false` and `upgrade = false`. A switch
  installs what the locked taps name and leaves upgrades to the apps
  themselves and to `nix flake update homebrew-cask`.
- `nix-homebrew.mutableTaps = false`, as `ncc:modules/homebrew.mod.nix:22`
  does.
- nix-homebrew's shell integrations are off: they would add `brew shellenv`
  to `/etc/zshrc` and the other shells' files, which every account reads.
  Its `brew` launcher still goes into `/run/current-system/sw/bin`, so `brew`
  is on her PATH too, naming the shared prefix (§9).

**Every GUI app on metal is a cask; Home Manager copies no apps.** Discord
stays `pkgs.discord` on Linux and is the `discord` cask on metal; Ghostty is
the `ghostty` cask, with `programs.ghostty.package = null` so Home Manager
writes its config alone.

- Home Manager's `targets.darwin.copyApps` rsyncs apps from the store into
  `~/Applications/Home Manager Apps`, and first checks that it may write
  inside each bundle there (`home-manager:modules/targets/darwin/copyapps.nix:42-96`).
  macOS lets a process change a vendor-signed bundle only if it holds the
  App Management permission. switcharoo activates from a launchd daemon,
  which can neither hold that permission nor be prompted for it, so the check
  aborts the switch, and with it off the copy itself would fail at the next
  update of either app.
- `copyApps` is off for Dylan (`home.mod.nix`, Darwin part). A cask installs
  a bundle once; with `upgrade = false`, `brew bundle` only confirms it is
  there, which works headless. Both apps then update themselves, like Brave.
- To undo by hand once: delete `~/Applications/Home Manager Apps`, which
  still holds the old copies.

### macOS defaults (`modules/desktop/darwin-desktop.mod.nix`)

This file is a `darwinModules.desktop` member. It starts with ncc's choices
that are taste-neutral and that a new Mac user would not miss:

- **Dock, effectively none** (Dylan, 19:25). It is set through
  `system.defaults.dock` (`nix-darwin:modules/system/defaults/dock.nix`):
  - `autohide = true`.
  - `autohide-delay = 1000.0`, so the Dock never slides in at the screen edge.
    This is the opposite of ncc's instant `0.0`
    (`ncc:modules/darwin-desktop.mod.nix:29-30`).
  - `show-recents = false`.
  - `persistent-apps = [ ]` and `persistent-others = [ ]`, so the Dock holds
    nothing pinned.
  - `static-only = true`, so running apps don't appear either.
  - Hot corners off (`wvous-*-corner = 1`).
  - Launching then goes through Spotlight (Cmd+Space) or the hotkeys below.
    The Dock itself still runs, because macOS has no supported way to remove
    it.
- **Finder:** `AppleShowAllExtensions = true`, `ShowPathbar = true`,
  `FXPreferredViewStyle = "Nlsv"`, `FXDefaultSearchScope = "SCcf"`.
- **Keyboard:** `NSGlobalDomain.KeyRepeat = 2`,
  `InitialKeyRepeat = 15`, `ApplePressAndHoldEnabled = false`.
- **Trackpad:** tap to click.
- **Screenshots** go to `~/Downloads` (`ncc:modules/darwin-desktop.mod.nix:76`).
- **Security:** screensaver password immediately. New documents save locally
  by default (`ncc:modules/darwin-unshittify.mod.nix:19`).
- **Only user domains.** nix-darwin writes the user domains (`dock`,
  `finder`, `NSGlobalDomain`, `screencapture`, `trackpad`,
  `CustomUserPreferences`) with `launchctl asuser` for `system.primaryUser`
  alone, so they reach Dylan's account only. `loginwindow`, `SoftwareUpdate`,
  `smb` and `CustomSystemPreferences` write `/Library/Preferences` for every
  account, so ncc's `GuestEnabled = false` is not carried over.
- **Touch ID for sudo** (`ncc:modules/sudo.mod.nix:29-32`). It applies only at
  the keyboard; over SSH sudo still asks for the password. It is a
  machine-wide PAM line (§9).
- **Not carried over:** quarantine off and macOS updates off
  (`ncc:modules/darwin-unshittify.mod.nix:22-25`). Both weaken defaults that
  protect a daily-use Mac.

### Hotkeys: Hammerspoon (`modules/desktop/hammerspoon.mod.nix`)

The file is named for its tool, as AGENTS.md asks of a tool that carries
configuration. It registers `darwinModules.hammerspoon` and makes it a
`darwinModules.desktop` member, as ncc does (`ncc:modules/hammerspoon.mod.nix:3-4`).
metal runs no tiling window manager (Dylan's decision): macOS keeps its own
window handling, and Hammerspoon adds only global keys that open apps.

- **Install:** the cask, `homebrew.casks = [ "hammerspoon" ]`
  (`ncc:modules/hammerspoon.mod.nix:10`), at the fixed path
  `~/Applications/Hammerspoon.app`.
- **Run at login:** `hs.autoLaunch(true)` in `init.lua`, which makes
  Hammerspoon a login item of Dylan's account alone. A Home Manager launchd
  agent is not used: its activation loads the agent into Dylan's GUI domain,
  which a switch run from switcharoo's system daemon may find absent when he
  is not logged in at the Mac. ncc's `launchd.user.agents` (`:19-26`) would
  install into `/Library/LaunchAgents` and start Hammerspoon for every
  account.
- **Config:** the module writes `~/.hammerspoon/init.lua`, Hammerspoon's
  default path, through
  `home-manager.users.${config.primaryUser}.home.file.".hammerspoon/init.lua"`.
  - Setting it from the Darwin module keeps it off the Linux hosts. A
    `homeModules` aspect would be mirrored to both platforms and need an
    `isDarwin` gate, as ncc's does (`:29-36`).
  - Because the default path is used, ncc's `MJConfigFile` preference (`:12`)
    is not needed.
- **Updates: departs from ncc.** ncc turns Hammerspoon's own updater off
  (`:14-16`). Here `homebrew.onActivation.upgrade = false` (Apps above), so
  turning the updater off would freeze Hammerspoon. It keeps its updater, as
  Brave does, and the path stays fixed across updates.
- **Reload on switch: a pathwatcher.** `init.lua` starts
  `hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", hs.reload):start()`,
  the pattern Hammerspoon's own guide uses. A switch replaces the
  `init.lua` symlink in that directory, the watcher sees the change, and
  Hammerspoon reloads itself. No step in the switch needs to reach the
  running app.
  - Not chosen: the `hs` CLI (`hs -c "hs.reload()"`) from an activation step.
    It needs `hs.ipc` loaded and the CLI installed. The switch also runs from a
    launchd system daemon over SSH, outside Dylan's GUI session, so reaching
    the app's IPC port from there is not assured.
  - Layer 4 confirms that the symlink swap fires the watcher.
- **Modifier: Option alone** (`{ "alt" }`; Dylan's decision).
  - Cmd plus a letter belongs to every app (Cmd+Q, W, N, R), so Cmd is out.
    Option is one key under the thumb, needs no driver, and sits where SUPER
    sits on the Linux hosts.
  - **Costs Dylan has accepted:**
    - The bound Option chords no longer type their characters. On the US
      layout that is ∑ (W), ® (R), ƒ (F), œ (Q) and the Option+N and Option+I dead keys, so
      ñ, î, ê and the other tilde and circumflex letters can't be typed that way (the press-and-hold
      accent menu is off too, under Keyboard above; the Character Viewer still
      works). Option+Return and Option+Escape type nothing, so those two cost
      no character.
    - With Ghostty's `macos-option-as-alt`, Alt plus those keys never reaches
      the terminal: readline's Alt-F (forward word), Alt-R (revert line) and
      Alt-N, and any terminal program's Alt-I, Alt-Q, Alt+W or Alt+Return. Alt-B,
      Alt-D and the other letters still work.
  - **Option+Escape collisions:** macOS's only default use is Speak Selection
    (System Settings → Accessibility → Read & Speak), whose shortcut is
    Option+Esc and which is off by default. If Speak Selection is ever turned
    on, its shortcut is moved. Force Quit is Cmd+Option+Esc, a different
    chord, and is unaffected.
- **Binds**, mirroring Hyprland's letters
  (`modules/desktop/hyprland/keybinds.mod.nix`). Each is
  `hs.hotkey.bind({ "alt" }, key, fn)`:

| Bind | Action | Lua | Hyprland source |
|---|---|---|---|
| alt-return | Ghostty | `hs.application.launchOrFocus("Ghostty")` | `keybinds.mod.nix:58` |
| alt-w | Brave | `hs.application.launchOrFocus("Brave Browser")` | `:102` |
| alt-r | lf in a new Ghostty window | `hs.task.new("/usr/bin/open", nil, { "-na", "Ghostty", "--args", "-e", "lf" }):start()` | `:91` |
| alt-n | nvim in a new Ghostty window | the same, with `nvim` | `:90` |
| alt-f | Finder | `hs.application.launchOrFocus("Finder")` | (none; F is free once nothing tiles) |
| alt-escape | lock the screen | `hs.caffeinate.lockScreen()` | `:109` |
| alt-q | quit the front app | `hs.application.frontmostApplication():kill()` | `:107` (close window there) |
| alt-i | toggle the idle inhibitor | `hs.caffeinate.toggle("displayIdle")`, then show or remove the indicator | `:116-118` |

  - `launchOrFocus` opens an app or brings it forward. R and N need a new
    window each time, so they go through `open -na`; whether Ghostty's macOS
    app honours `-e` passed this way is checked in layer 4.
  - `kill()` asks the app to terminate normally, so its own save and confirm
    prompts still run. `kill9()`, the forced kind, is not used.
  - Ghostty is the `ghostty` cask in `~/Applications`; the shared Home
    Manager `programs.ghostty` writes its config.
  - Left out on purpose: close window (Cmd+W already does it), and the email,
    messenger and password-manager binds (`:69,89,93`). Their apps come from
    `desktopApps` on Linux and have no macOS counterpart in this plan yet;
    each joins the table when its app joins metal.
- **Idle inhibitor.** `hs.caffeinate.toggle("displayIdle")` keeps the display,
  and with it the Mac, from sleeping while idle, and returns the new state.
  While it is on, an `hs.menubar` item shows a small cup in the menu bar;
  turning it off deletes the item, and clicking the item turns it off too.
  The state is not persisted. A logout ends it, and a switch that changes
  `init.lua` reloads Hammerspoon, which is expected to release it; layer 4
  confirms that the cup and the state go together.
- **Room to grow.** Hammerspoon can later carry window snapping
  (`hs.window`), Wi-Fi, power or USB watchers, and similar. Each would be a
  section of the same `init.lua`, under the same grant. None of it is planned
  now.

#### Not chosen

- **skhd** (through nix-darwin's `services.skhd`): in maintenance mode, with no
  release since v0.3.9 (tagged 2023-05-27). Its binary lives in the Nix store,
  so an update can move the path that the Accessibility grant is tied to.
- **skhd.zig:** not in nixpkgs, and it does less than Hammerspoon.
- **Ctrl+Option or Hyper as the modifier.** Ctrl+Option loses no symbols, but
  it is VoiceOver's modifier and two keys to hold. nix-darwin can remap Caps
  Lock only to a single key (`nix-darwin:modules/system/keyboard.nix:17-27,59-66`,
  applied with `hidutil` at `:116`), not to a chord, so Hyper needs
  Karabiner-Elements: a DriverKit system extension approved at the keyboard,
  Input Monitoring, and a second daemon.

#### Ghostty

The Hyprland-specific Ghostty settings (`window-decoration = "none"`, opacity
relying on compositor blur, Insert-key binds) stay in the Linux part, with the Comic Code font, which only the Linux
hosts install. The padding is shared. The Darwin part sets
`macos-titlebar-style = "hidden"` and `macos-option-as-alt = true`; Ghostty
updates itself.

### Dictation: Hex (`modules/desktop/hex.mod.nix`, Darwin part)

Hex runs on metal as on the Linux desktops, with Caps Lock starting and
stopping a dictation. The concern file keeps both platforms: the Linux part
as today (`modules/desktop/hex.mod.nix:11-21`), plus a `darwinModules.hex`
that joins `darwinModules.desktop`.

- **Install: the vendor's cask, from Hex's own tap.**
  - The flake has no Darwin support anywhere. Its `systems` list is
    `x86_64-linux` and `aarch64-linux` only (`hex:flake.nix:15-18`). Its
    home-manager module asserts those two systems (`hex:nix/hm-module.nix:107-112`)
    and runs Hex as a systemd user service (`:126-145`).
  - Hex publishes a cask, `anomalyco/tap/hex` (`hex:README.md:32`). Its
    release pushes it to `anomalyco/homebrew-tap` (`hex:.github/release/push-homebrew.sh:2-4`).
    The cask installs `Hex.app`, needs arm64 and Sequoia or later, and
    updates itself (`hex:packaging/homebrew/hex.rb:17-21`).
  - So metal takes the cask. A `fetchurl` DMG package would repeat what the
    cask already does, and would fight Hex's self-updater.
  - A fourth input, `homebrew-anomalyco = { url = "github:anomalyco/homebrew-tap"; flake = false; }`,
    joins `nix-homebrew.taps` as `"anomalyco/homebrew-tap"`, beside
    `homebrew-core` and `homebrew-cask` (§3, Inputs), with
    `homebrew.casks = [ "anomalyco/tap/hex" ]`.
- **The Linux home aspect stays off metal.** Because of that assertion,
  `homeModules.hex` must not stay in `homeModules.desktop`, which the plan
  mirrors onto Darwin (§3, Collections). The Linux part instead imports it
  from `nixosModules.desktop`, through
  `home-manager.users.${config.primaryUser}.imports`.
- **Start at login:** Hex's own `hex launch-at-login on`
  (`hex:docs/cli.md:85`), run by the same activation step as the settings,
  for the reason Hammerspoon uses its own login item. It needs Hex running,
  so it holds from the first switch after Hex has been opened once.
- **Settings:** the activation step runs `hex settings apply` with
  `shortcut_mode = "toggle"`, `labs.caps_lock_dictation = true` and
  `dictation_hotkey = "f18"`, as Hex's Linux module applies its settings
  (`hex:nix/hm-module.nix:117-124`). F18 moves the normal shortcut off the
  Option key the hotkeys use.
- **Caps Lock: two ways, Dylan's choice (§9).** The remap below is the
  established route, but `hidutil` mappings are global: they change Caps Lock
  for every account, hers included, until the next restart, and nix-darwin's
  boot daemon reapplies them at every boot. The per-user route is Hex's own
  Labs Caps Lock dictation (the last bullet here), which is a Hex setting in
  Dylan's account and changes no key. Recommended: try the Labs feature
  first in layer 4, and keep the remap as the fallback only if she agrees to
  lose Caps Lock.
- **The remap: Caps Lock to F18, which Hex's own shortcut listens for.**
  - nix-darwin sets `system.keyboard.enableKeyMapping = true` and one
    `system.keyboard.userKeyMapping` entry:
    `HIDKeyboardModifierMappingSrc = 30064771129` (Caps Lock, 0x700000039)
    to `HIDKeyboardModifierMappingDst = 30064771181` (F18, 0x70000006D).
    - nix-darwin applies it with `hidutil` at every switch
      (`nix-darwin:modules/system/keyboard.nix:113-116`), and its boot-time
      `activate-system` daemon reapplies it after a restart
      (`nix-darwin:modules/services/activate-system/default.nix:69`).
    - `userKeyMapping` is marked internal (`keyboard.nix:59-60`), but it is
      the list that nix-darwin's own `remapCapsLockTo*` options fill
      (`:75-78`), and there is no public option for an arbitrary target.
  - Hex's own shortcut is set to F18, in Toggle mode. Hex accepts a standalone
    function key as its shortcut (`hex:docs/features/dictation.md:24-27`).
    - Hex's default shortcut is Option alone (`dictation.md:24`). That would
      collide with every Hammerspoon bind, so it must be changed anyway, and
      F18 is the replacement.
    - The settings are those monix sets on Linux (`hex.mod.nix:16-20`):
      `dictation_hotkey` and `shortcut_mode = "toggle"`. A home-manager
      activation step writes them with
      `~/Applications/Hex.app/Contents/MacOS/hex settings set …`
      (`hex:docs/transcript-cli.md:4`; `hex:docs/cli.md:459`), the route Hex's
      own module takes. A running Hex adopts the change at once, and a stopped
      Hex finds it in `settings.json` (`hex:nix/hm-module.nix:62-77`).
  - Why not Hammerspoon running `hex dictation toggle`, as Hyprland runs the
    CLI (`modules/desktop/hyprland/keybinds.mod.nix:271-278`)? On Linux the
    CLI works around portal shortcut ids that Hex renames (`:271-275`). On
    macOS Hex reads its own shortcut, so there is nothing to work around, and
    Hex's own shortcut also drives its cancel key and its Toggle lock. If F18
    proves unreliable, the fallback is a Hammerspoon F18 bind that runs the
    CLI.
  - **The per-user route:** Hex's own Labs › Caps Lock dictation
    (`labs.caps_lock_dictation`), which needs no remap and lights the Caps
    Lock key while it records. It is a Labs feature, off by default, and "not
    verified on hardware" (`hex:docs/features/dictation.md:49-69`), and it
    needs Input Monitoring. The same `hex settings set` step turns it on.
- **End stays Linux-only.** The MacBook Air keyboard has no End key; Fn+→
  acts as End in text, and taking it globally would break moving to the end
  of a line.
- **Model:** Hex's first run downloads the speech model, as its onboarding
  does. The Linux `installModel` service is systemd-only.
- **Permissions** (manual steps, §7):
  - Microphone and Accessibility. Hex names both in its `Info.plist`
    (`hex:app/Info.plist:42-51`), and Accessibility drives its key event tap
    and paste (`hex:crates/capture/src/permissions.rs:24-30`).
  - Input Monitoring: needed only for the Labs Caps Lock route
    (`permissions.rs:12-14`).
  - Speech Recognition: not on Tahoe (`permissions.rs:17-19`).
  - Screen Recording is asked only for Hex's screen-capture feature (`:26-30`),
    which dictation doesn't use.

## 5. switcharoo on macOS

Built on branch `metal-switcharoo`. As built, it differs from the table
below in three ways:

- **The job runs the deploy by a stable path.** nix-darwin's activation
  unloads and reloads every daemon whose plist changed
  (`nix-darwin:modules/system/launchd.nix:18-31`), which would kill the
  deploy running it. So the plist runs
  `/run/current-system/sw/bin/switcharoo-deploy`, never a store path, and
  stays the same across generations, as `restartIfChanged = false` does on
  NixOS.
- **sshd is judged by probes, not its job.** macOS's `com.openssh.sshd` is
  started per connection, so between connections it is never "running".
  The health check runs `sshd -t` and `nc -z 127.0.0.1 22` instead, plus
  `tailscale status`. `must-run` defaults to `com.tailscale.tailscaled`.
- **Newly failed jobs** are those daemons in the new system's
  `Library/LaunchDaemons` whose `last exit code` turns non-zero, skipping
  calendar jobs as NixOS skips timers.

`modules/core/switcharoo.mod.nix` stays one file and one deploy script. The
platform enters only where the two systems differ.

| Step | NixOS (today) | Darwin |
|---|---|---|
| Lock | `flock` on `/run/switcharoo.lock` (`:58-59`) | the same; `/run` exists on Darwin through nix-darwin; `pkgs.flock` in place of util-linux |
| Fetch, fence, refuse without `--approve` | `:71-110` | unchanged; GitHub monix is public, so root needs no credential |
| Running revision | `nixos-version --configuration-revision` (`:79`) | `darwin-version --configuration-revision` (`nix-darwin:pkgs/nix-tools/darwin-version.sh:30-31`) |
| Build | `nixosConfigurations.${host}` (`:112-113`) | `darwinConfigurations.${host}` |
| Snapshot of failures | `systemctl list-units --failed` (`:119`) | `launchctl list`, rows labelled `org.nixos.*` with a non-zero last status |
| Activate | `switch-to-configuration test` (`:126`) | `nix-env --profile /nix/var/nix/profiles/system --set "$system"`, then `$system/activate` |
| Settle | job queue, then 30 s (`:132-136`) | 30 s; launchd has no job queue |
| Newly broken | `comm -13` on the snapshots (`:137-145`) | the same comparison of the launchd snapshots |
| Must be running | `systemctl is-active` per `/etc/switcharoo/must-run` (`:148-153`) | `launchctl print system/<label>` per entry; defaults `com.openssh.sshd` and `org.nixos.tailscaled`, plus `tailscale status` succeeding, because the tailnet is the only way in |
| Roll back | `$previous/bin/switch-to-configuration test` (`:159`) | `nix-env --profile … --set "$previous"`, then `$previous/activate` |
| Commit | `nix-env --profile … --set` then `switch-to-configuration boot` (`:164-165`) | nothing; activate already set the profile |
| Kernel note | `:168-170` | omitted |

On Darwin the profile must name the new system before it activates, as
`darwin-rebuild switch` orders it (`nix-darwin:pkgs/nix-tools/darwin-rebuild.sh:240-248`).
Activation reloads the `activate-system` daemon, which runs at load and sets
up `/etc/static` and `/run/current-system` from whatever the profile names
(`nix-darwin:modules/services/activate-system/default.nix`). With the profile
still on the previous system, that daemon would put the previous system's
`/etc` back underneath the new one. Rollback restores the profile before it
reactivates the previous system, so a failed deploy leaves the boot default
where it was; only a reboot during the test window lands on the untested
system.

### Units and trigger

| | NixOS | Darwin |
|---|---|---|
| Deploy job | `systemd.services.switcharoo` (`:281`) | `launchd.daemons.switcharoo` (label `org.nixos.switcharoo`, no `RunAtLoad`, output to `/var/log/switcharoo.log`, rotated by `newsyslog`) |
| Approved job | `switcharoo-approved` (`:282`) | `launchd.daemons.switcharoo-approved` |
| Password-free start | polkit rule for `switcharoo.service` start by `cfg.users` (`:284-294`) | `security.sudo.extraConfig` with one line per user in `cfg.users`: `<user> ALL=(root) NOPASSWD: /bin/launchctl kickstart system/org.nixos.switcharoo`. sudoers matches the exact arguments, so nothing else, including the approved job, is password-free |
| `--approve` | `sudo systemctl start switcharoo-approved.service` (`:201`) | `sudo launchctl kickstart system/org.nixos.switcharoo-approved`, which asks for the admin password |
| CLI wait | job queue, then `Result` (`:220-227`) | poll `launchctl print` for `state` and `last exit code`; follow the log from its size at start |

`cfg.users` defaults to the primary user, because there is no seat on Darwin.
Water's workers SSH in as that user and run `switcharoo`. The sudoers line
lives in `switcharoo.mod.nix`, as the polkit rule does today, so it is fenced.

The header comment's emergency line gains its Darwin twin:
`darwin-rebuild switch --flake`.

### What stays true

- Only pushed `main` deploys.
- Fenced commits need `--approve`, and that is Dylan's to run.
- A failed activation, a newly failing job or a lost sshd, tailscaled or tailnet
  rolls back.
- Only a healthy system becomes the default at boot.

### What is weaker on Darwin

- Homebrew steps run inside activation. With `cleanup = "none"`, a cask added
  by a rolled-back generation stays installed after the previous generation
  reactivates; it is removed by hand if unwanted.
- `system.defaults` writes are not undone by rollback beyond what the previous
  generation writes again.

## 6. Bootstrap

Steps 1 to 3 are done (2026-11-14): the official Nix installer is in, Remote
Login is on, and metal's host key is in `keys.nix` as `hosts.metal`. Dylan
does the rest once, at the Mac's keyboard, in his own account.

1. **Install Nix** with the official installer,
   `sh <(curl -L https://nixos.org/nix/install)` (done). Not Lix and not
   Determinate (§1).
2. **Remote Login** on (done). nix-darwin finds it on and leaves it alone.
3. **Host key** recorded in `keys.nix` (done). metal holds no secrets in the
   layers below; the key is there for when it does, such as the App Store
   Connect API key.
4. **First switch, from a local clone of the `metal` branch:**
   ```sh
   git clone --branch metal https://github.com/dycli/monix.git ~/monix
   cd ~/monix
   sudo NIX_CONFIG="extra-experimental-features = nix-command flakes pipe-operators" \
     nix run nix-darwin#darwin-rebuild -- switch --flake .#metal
   ```
   This follows `nix-darwin:README.md:86-92`, plus `pipe-operators`, which
   monix needs before its first switch (AGENTS.md, Pipe operators). Once the
   branch is merged, the clone drops `--branch metal` and follows `main`.
   - nix-darwin moves the official installer's `/etc/nix/nix.conf` aside
     itself, because it knows the file's hash. If activation stops on
     "Unexpected files in /etc", rename each file it names with a
     `.before-nix-darwin` suffix (`sudo mv /etc/<f> /etc/<f>.before-nix-darwin`)
     and rerun.
   - Then open a new terminal: Dylan's shell is now nushell through
     Home Manager's `~/.zshrc`.
5. **Tailscale handover, at the keyboard (never over SSH).**
   1. Confirm the other account does not use the Tailscale app herself (§9).
   2. Quit and remove the Tailscale GUI app.
   3. Run `sudo tailscale up --hostname=metal`.
   4. Approve the new node.
   5. Remove the old `gabs-mac-dylan` node from the admin console.
   - The node gets a new identity and address, so Water's references follow
     the new address.
6. **Layer 2 checks**, from Water and on metal:
   - `ssh dylan@metal` from the seat succeeds with its key.
   - `sudo sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers)'`
     prints `no`, `no`, `no` and `dylan`. macOS's own
     `/etc/ssh/sshd_config.d/100-macos.conf` sorts before nix-darwin's
     `100-nix-darwin.conf`, and sshd keeps the first value it reads, so this
     confirms nothing in macOS's file wins.
   - `darwin-version --configuration-revision` names the pushed commit.
   - In her account, Terminal opens with its usual prompt and her apps are
     where they were.
7. **From then on,** every change is `git push`, then `switcharoo` on metal,
   which Water's workers can run (layer 3).

The host config replaces these of Bridge's manual steps:

- Remote Login with Water's key becomes `openssh` plus `authorizedKeys`.
- The Xcode install becomes `masApps`.
- `xcode-select` becomes the activation step.
- Stay-awake becomes `pmset -c`.
- Nix settings become `nix.mod.nix`.

Developer enrolment and the Nix installer itself stay manual.

## 7. What stays manual, and risks

### Manual

- The Apple ID and the App Store sign-in. `mas` cannot sign in on current
  macOS.
- Apple Developer Program enrolment.
- The Xcode licence and first launch: `sudo xcodebuild -license accept`, once
  per major Xcode.
- Signing certificates and the App Store Connect API key. A later layer can
  hold the key in agenix, encrypted to metal's host key.
- The Tailscale handover (§6 step 5).
- Hammerspoon's Accessibility permission (System Settings → Privacy &
  Security → Accessibility), once. The app sits at the fixed path
  `~/Applications/Hammerspoon.app`, so the grant survives updates.
- Hex's Microphone and Accessibility permissions, once, at its first launch,
  and its speech model download through its onboarding (§4, Dictation).
  Input Monitoring only for the Labs Caps Lock route; Speech Recognition is
  not needed.
- macOS updates.

### Risks

- **Losing the way in.** A bad switch that breaks sshd or tailscaled while
  Dylan is away. The health check includes both plus `tailscale status`, and
  rolls back. Changes to `ssh.mod.nix`, `users.mod.nix` and `switcharoo.mod.nix`
  are fenced.
- **The lid.** A MacBook sleeps with the lid closed unless an external display
  is attached, whatever `pmset` says. Dylan keeps it open. `pmset
  disablesleep 1` is possible, but it keeps a closed laptop running in a bag,
  so it is not proposed.
- **Xcode updates.** If App Store auto-update moves Xcode to a new major
  mid-cycle, builds break until the licence is accepted again. Dylan chose
  auto-update off, but that setting is machine-wide and also stops her App
  Store apps updating themselves, so it is reopened in §9. Pinning an exact
  Xcode needs `xcodes` and Apple credentials, and is deferred.
- **Builds while she uses the Mac.** Builds and `xcodebuild` from Water run as
  Dylan, and they take CPU from her session. The MacBook Air has no fan: a
  long build heats the case and throttles both. The Nix daemon can run at
  macOS's background priority, and a build run over SSH can be wrapped in
  `taskpolicy -b` (§9).
- **Activation length.** `brew bundle` and `mas` run on every switch and need
  the network. A cask that fails to download fails activation, and switcharoo
  rolls back. That is correct, but it is noisy.
- **launchd semantics.** Using `launchctl print` output for health and
  completion depends on fields Apple does not document as stable. Layer 3
  checks them on Tahoe before relying on them.
- **Shared evaluation.** Evaluating metal must not fetch the private inputs
  (Libri, hippo2, hob, jobmaxxer). Root on metal has no GitHub credential.
  Nothing on the metal path imports them. Layer 1 proves it by evaluating as a
  user with no credential.
- **The tailnet name.** `gabs-mac-dylan` names the Mac's other account. The
  Mac is shared, Dylan's account is `dylan`, and nothing here names hers.
- **Her account.** nix-darwin creates or changes only the users and groups
  in `users.knownUsers` and `users.knownGroups`. Its own Nix module lists
  the `_nixbld` build accounts and the `nixbld` group there, which the
  installer already made. An assertion in `users.mod.nix` fails the build if
  any other name is ever added, so a later change cannot reach her account.

## 8. Layers

Each layer works end to end before the next starts.

1. **Metal evaluates on Water.** Built on branch `metal`.
   - Added the `nix-darwin` input, `lib.ship.darwinHost`, `darwinModules` and
     `commonModules` in `flake-outputs.mod.nix`.
   - Split `nix`, `binary-cache`, `home`, `users`, `ssh`, `tailscale`,
     `packages`, `nushell` and `ghostty` into their common and platform parts;
     `host` and `agent-clis` became common.
   - `secrets` is not split: metal holds no secrets yet, so the split waits
     for its first one.
   - Added `hosts/metal/metal.mod.nix` and the `eval-metal` check.
   - Done: the NixOS hosts' toplevels are unchanged (the same `drvPath`
     before and after, with `configurationRevision` pinned; Water's differs
     only by `eval-metal` in ship-check's list and its atlas), and
     `ship-check` is green with `eval-metal`.
   - The merge is fenced, because `users.mod.nix`, `ssh.mod.nix` and
     `keys.nix` change.
2. **Metal switched.** Its host config is in layer 1.
   - Bootstrap per §6.
   - The host carries SSH, Tailscale, Nix, shell and git.
   - Done when Water reaches `metal` over the tailnet with its key, and
     `darwin-version --configuration-revision` matches `main`.
3. **switcharoo on metal.** Built on branch `metal-switcharoo`.
   - Port per §5.
   - Done when a harmless commit deploys from Water's SSH session without a
     password, a deliberately broken commit (tailscaled disabled) rolls back by
     itself, and a fenced commit refuses until `--approve`.
4. **Apps and the build role.**
   - Add `nix-homebrew` and the taps, and `darwin-desktop.mod.nix`.
   - Add the Brave, Hammerspoon and Hex casks (the last from the pinned
     `anomalyco/homebrew-tap`), the Caps Lock remap, and the `apple-build` bundle: Xcode through `masApps`,
     `xcode-select` and `pmset` (`pmset` built).
   - Add `hammerspoon.mod.nix` and the Dock defaults.
   - Done when:
     - Brave and Xcode are installed by the switch, Brave into
       `~/Applications`.
     - Her account sees none of the casks, and her apps are unchanged.
     - The Dock never appears.
     - Hammerspoon starts at login, and each hotkey does its action:
       Option+Q quits Brave normally, and R and N open lf and nvim in new
       Ghostty windows.
     - A switch that changes `init.lua` reloads Hammerspoon through the
       pathwatcher, without logging out.
     - Discord opens from Spotlight and does not update itself.
     - Option+I shows the menu bar cup and keeps the display awake past its
       timeout; pressing it again removes the cup.
     - Caps Lock starts and stops a Hex dictation in Dylan's account and
       still does after a restart; in her account it is still Caps Lock
       (on the Labs route).
5. **Libri's iOS shell.** This is in the Libri repository, not monix.
   - Add `nix develop .#ios` with rust-overlay's iOS targets and `xcodegen`.
   - Done when a worker on Water builds the Rust core for
     `aarch64-apple-ios-sim` on metal over SSH.

## 9. Machine-wide settings, for Dylan to decide

**Decided (Dylan, 2026-11-14):** Hex's own per-user Caps Lock dictation, with
no `hidutil` remap; App Store auto-update stays on; `pmset -c sleep 0`
stays; `nix.daemonProcessType = "Background"` (built with layer 3); Homebrew
`cleanup = "none"`, with `/opt/homebrew` left usable by the other account.
Tailscale stays as built: her account joins Dylan's tailnet from her own
devices only, and the system `tailscaled` serves her session on the Mac too.

Answered (2026-11-14): Homebrew for GUI apps and Xcode, yes; the
password-free sudoers line, yes; the open-source `tailscaled` renamed
`metal`, yes; the lid stays open; `primaryUser` is `dylan`; the official
Nix installer. Hammerspoon with Option alone and its eight binds is settled.

What cannot be scoped to Dylan's account, with its effect on the other
account and a recommendation. Each needs Dylan's word.

| Setting | Layer | Effect on her account | Choice | Recommended |
|---|---|---|---|---|
| Caps Lock to F18 (`hidutil`) | 4 | Her Caps Lock stops working, from the first switch and after every boot | (a) Hex's Labs Caps Lock dictation, per-user, no remap; (b) the remap, if she agrees; (c) a different Hex key | (a), with (b) as the fallback only with her agreement |
| `pmset -c sleep 0` | 4 | On the charger the Mac never sleeps, for her too; the display still sleeps at 10 minutes; battery is unchanged | (a) as planned; (b) leave sleep alone and keep builds short | (a): she sees no difference beyond a warm Mac on the charger |
| App Store auto-update off | 4 | Her App Store apps stop updating themselves too (`/Library/Preferences/com.apple.commerce`) | (a) off, as Dylan chose; (b) leave it on and accept that a new Xcode can break a build until its licence is accepted | (b): Xcode majors are rare, and (a) quietly leaves her apps unpatched |
| Casks | 4 | None for `~/Applications` casks. Xcode and `.pkg` casks land in `/Applications`, which she sees | as planned | as planned |
| Homebrew prefix `/opt/homebrew` | 4 | One prefix per Mac. With `cleanup = "none"` nothing of hers is removed. If she already uses Homebrew, nix-homebrew must take the prefix over (`autoMigrate`) and then pins its taps | checked: `/opt/homebrew` does not exist on metal, so nix-homebrew creates it, owned by Dylan with group `admin`, and no `autoMigrate` is needed. `brew` is on every account's PATH through `/run/current-system/sw/bin`; the shell integrations are off | as planned |
| `tailscaled` replacing the GUI app | 2 | A system daemon on Dylan's tailnet whenever the Mac is on, whoever is logged in. Only `*.ts.net` names go to Tailscale's DNS (`overrideLocalDns` stays off), so her browsing is unchanged. Removing the app removes it for her too; she cannot run the GUI app beside the daemon | ask whether she uses Tailscale herself | as planned, if she does not |
| Remote Login | 2 | Already on. `sshd` listens on every interface, but keys alone admit and `AllowUsers dylan`, so her account cannot be logged into over SSH | as built | as built |
| sudoers line | 3 | Grants Dylan alone one exact `launchctl kickstart` command. nix-darwin also keeps `TERMINFO` for `sudo` (`/etc/sudoers.d/10-nix-darwin-extra-config`) and writes an empty `/etc/pam.d/sudo_local`. No effect on her | as planned | as planned |
| Touch ID for sudo | 4 | A machine-wide PAM line: if she is an administrator with a fingerprint enrolled, her `sudo` accepts Touch ID too | (a) on; (b) leave out | (a): harmless to her |
| Nix itself | 2 | Already there from the installer: the `/nix` volume, `nix-daemon`, the hidden `_nixbld` accounts and the installer's lines in `/etc/zshrc` and `/etc/bashrc`, which put Nix on her `PATH`. The switch adds `/etc/nix`, `/etc/ssl/certs/ca-certificates.crt`, `/etc/resolver/ts.net`, `/run/current-system` and the daemons `activate-system`, `nix-gc` and `nix-optimise`. Her prompt and shell stay macOS's | as built | as built |
| Host name | 2 | `HostName` and `LocalHostName` become `metal` (Bonjour `metal.local`) for the whole Mac. The Computer Name she sees in AirDrop and Finder is unchanged | as built | as built |
| Build priority | 3 | Builds from Water take CPU and heat from her session (no fan) | (a) `nix.daemonProcessType = "Background"`, macOS's low CPU and I/O class, with `nix.settings.max-jobs` and `cores` capped; (b) as is | (a), and `taskpolicy -b` around `xcodebuild` over SSH |

`nix.daemonProcessType` defaults to `"Standard"` in nix-darwin
(`nix-darwin:modules/nix/default.nix:252-265`); `"Background"` makes macOS
favour her session over a build at every moment, at the price of slower
builds while she is using it.
