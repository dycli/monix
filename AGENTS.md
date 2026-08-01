# Conventions

This repository follows the **Dendritic Pattern**: every `*.mod.nix` file in the
tree is a flake-parts module and is discovered automatically by `flake.nix`.
There is no central module list. A file's directory is organisational only.

## Module shape

Each `*.mod.nix` is a flake-parts module. It typically registers one or more
*aspects* into a collection:

- `flake.nixosModules.<name>`  — NixOS aspects.
- `flake.homeModules.<name>`   — Home Manager aspects, applied to every
  managed user on hosts that import them.

A single concern file may register several aspects at once — e.g. `hyprland.mod.nix`
defines both `nixosModules.hyprland` (compositor) and `homeModules.hyprland`
(session). Group files by concern, not by aspect target; there is no `home/`
directory.

`self` and `inputs` are flake-parts top-level module arguments. Inner aspect
modules close over them lexically; they are not passed through NixOS specialArgs.

## Bundles

Hosts are composed from *bundles*: named attributes of the same collections
that several files contribute to. An aspect declares its membership next to
its registration:

```nix
flake.nixosModules.desktop = self.nixosModules.audio;
```

The collections are typed in `options/flake-outputs.mod.nix` so definitions
of one attribute merge, overlapping membership dedups (an aspect may join
several bundles), and each `homeModules` attribute is mirrored into the
same-named `nixosModules` attribute via `home-manager.sharedModules`.

Current bundles:

- `default`  — universal aspects; every host gets it from `lib.ship.host`.
  Self-gated service aspects live here too: their `enable` options exist on
  every host and default off.
- `desktop`  — a graphical workstation, independent of session choice.
- `hyprland` — the Hyprland/DMS session. A sibling (e.g. `kde`) is the seam
  for a host that runs a different session.
- `dev`      — the authoring toolchain and agent CLIs, for hosts where a
  human or the seat develops. A desktop is not automatically one.
- `homelab`  — the house's services: media, family apps, smart home, their
  front door and alerting.
- `ai`       — the agent cluster: cockpit seat, worker fleet, local
  inference. Needs `dev` imported alongside it. Shares a box with
  `homelab` today; either can move alone.

Rules of taste: never create a bundle without a real member and a real
importer (no speculative structure — promote shared host config into a
bundle when the second consumer appears); bundles do not import other
bundles — a host file lists all its layers explicitly; name bundles for
their contents or role, not for a single machine.

## Hosts

Hosts in `hosts/<name>/<name>.mod.nix` build their configuration with the
constructor:

```nix
imports = lib.lists.singleton (lib.ship.host "fw3" ({ ... }: {
  imports = [ self.nixosModules.desktop self.nixosModules.hyprland ];
  # hardware, disk layout, identity, credentials …
}));
```

`lib.ship.host` imports `default` and sets the hostname. The host file keeps
only what is true of the physical machine (hardware quirks, disk layout,
`primaryUser`, secret declarations and the options consuming them) plus its
bundle imports and per-service flips. Do not reintroduce a host-class
option; class is expressed by which bundles a host imports.

## Optional aspects must self-gate

`default` is imported by every host, so an optional aspect there must be
inert until switched on: service aspects gate their `config` with `mkIf` on
their service's `enable` option (e.g. `mkIf config.services.immich.enable`),
which a host or role bundle turns on. Aspects in the other bundles apply
unconditionally; their gate is bundle membership.

## Nix style

- Always `let inherit (lib.<path>) foo;` with full paths, e.g.
  `lib.lists.singleton`, `lib.modules.mkIf`, `lib.meta.getExe`.
- Prefer `lib.lists.singleton x` over `[ x ]`.
- Do not use `builtins.` inside modules; use the `lib.*` equivalents.
- Never use `rec`.
- The ship's own library is `lib.ship.*` (fences, hardened, topology, guide),
  threaded through every eval — never import `lib/*.nix` by relative path.
- One sanctioned broad inherit: `inherit (lib) types;` (and top-level
  re-exports with no namespaced home, e.g. `baseNameOf`). Everything else
  names its full path.
- Prefer `getExe`/`getExe'` over bare command names in scripts and exec lines.
- Prefer setting individual options with `mkIf` over wrapping whole attrsets:
  `foo.bar = mkIf c v;` not `foo = mkIf c { bar = v; };`.
- Put a blank line between unrelated options.
- Section comments are uppercase, no trailing period: `# AI STACK`.

## Comments

Comments state constraints and reasons the code cannot show — never what the
next line does. Assume a reader fluent in Nix and Linux: if an expression is
obvious, it gets no comment, or at most a short title. A comment that merely
narrates its assignment is noise; delete it. Prefer one tight sentence over a
paragraph, and never let commentary crowd the code it serves.

Comments must stand alone: they describe what is in the code, for a reader
with no access to any prior discussion. Never reference removed code, past
designs, or decisions-in-progress — history lives in git, plans live
elsewhere. A removal criterion is fine when it is concrete and in-code
("drop this override once the nixpkgs pin carries the fix").

## Packages

A package lives in the file for its concern; it is never scattered into an
unrelated module.

- A tool that carries configuration gets its own concern file, package and
  settings co-located (`git.mod.nix`, `ghostty.mod.nix`). Name the file for the
  tool/concern.
- Tools coupled to another concern live in that concern's file — `nh` and
  `nix-output-monitor` are in `nix.mod.nix`, font packages in `fonts.mod.nix`.
- Config-less tools with no natural home live in `modules/packages.mod.nix`:
  one universal system list, plus home lists that are bundle members
  (`desktop`, `homelab`). Differentiation comes from bundle membership.

Home aspects are expressed with home-manager (`home.packages`,
`programs.<tool>`).

## Secrets

`secrets.nix` is the agenix rule set (read by the CLI, not the flake). Add a
line there for each new secret before creating it with `agenix -e <path>.age`.
Reference secrets in modules as `config.secrets.<name>.path`.

## Pipe operators

Prefer `x |> f |> g` over nested calls when an expression is a genuine
pipeline — three or more transformations of one value. Do not decorate
single applications with `|>` or `<|`; plain application reads better and
stays familiar. The `pipe-operators` feature is enabled in
`nix.settings.experimental-features` (nix.mod.nix); a machine evaluating
the flake before its first switch passes it by hand
(`NIX_CONFIG="extra-experimental-features = pipe-operators"`). flake.nix
itself stays pipe-free so a stock parser can always read it.
