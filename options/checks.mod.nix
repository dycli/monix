# Flake checks: `nix flake check` proves the ship's own software builds and
# its test suites pass, and that the agenix rulebook is consistent — not just
# that the Nix evaluates.
#
# The crates build here without the deployment env the service modules bake
# in (all of it is option_env! with safe defaults), so these are test gates,
# not the production binaries.
{ self, ... }:
{
  systems = [ "x86_64-linux" ];

  perSystem =
    { pkgs, lib, ... }:
    let
      inherit (lib) baseNameOf;
      inherit (lib.attrsets) attrNames;
      inherit (lib.lists) elem filter;
      inherit (lib.strings) hasSuffix removePrefix;

      crate =
        path: extras:
        pkgs.rustPlatform.buildRustPackage (
          {
            pname = "${baseNameOf path}-check";
            version = "0";
            src = "${self}/${path}";
            cargoLock.lockFile = "${self}/${path}/Cargo.lock";
            # Lint gate rides the test build: warnings are errors here (the
            # gate) without polluting the production module builds.
            nativeBuildInputs = [ pkgs.clippy ];
            postCheck = "cargo clippy --all-targets -- -D warnings";
          }
          // extras
        );

      cratePaths = [
        "modules/server/agent-dispatch"
        "modules/server/agent-vm"
        "modules/server/fleet-tool/fleet-cli"
        "modules/server/memo/memo-cli"
        "modules/server/ship-costs/ship-costs-cli"
        "modules/server/alerts/ship-alert"
      ];

      # Every tracked *.age must have a rule in secrets.nix and every rule
      # must point at a tracked file — a new secret can't silently lack an
      # owner, and a deleted one can't leave a dangling rule.
      ruled = attrNames (import "${self}/secrets.nix");
      tracked = filter (path: hasSuffix ".age" path) (
        map (path: removePrefix "${self}/" (toString path)) (lib.filesystem.listFilesRecursive self)
      );
      unruled = filter (path: !elem path ruled) tracked;
      dangling = filter (path: !elem path tracked) ruled;
    in
    {
      # `nix fmt` formats the tree; the nixfmt check below keeps it canonical.
      formatter = pkgs.nixfmt-rfc-style;

      checks = {
        agent-dispatch = crate "modules/server/agent-dispatch" { };
        agent-vm = crate "modules/server/agent-vm" {
          # Fixture tests drive the same external tools the supervisor
          # uses at runtime (see agent-vm.mod.nix).
          nativeCheckInputs = [
            pkgs.jq
            pkgs.sqlite
          ];
        };
        fleet-cli = crate "modules/server/fleet-tool/fleet-cli" { };
        memo = crate "modules/server/memo/memo-cli" { };
        ship-costs = crate "modules/server/ship-costs/ship-costs-cli" { };
        ship-alert = crate "modules/server/alerts/ship-alert" { };

        rustfmt =
          pkgs.runCommand "rustfmt-check"
            {
              nativeBuildInputs = [
                pkgs.rustfmt
                pkgs.findutils
              ];
            }
            ''
              ${lib.strings.concatMapStrings (path: ''
                # The store copy of a crate has no target/ (untracked), so a
                # bare find over the crate root is exactly src + tests.
                find ${self}/${path} -name '*.rs' \
                  | xargs --no-run-if-empty rustfmt --edition 2024 --check
              '') cratePaths}
              touch $out
            '';

        # Enforces the AGENTS.md rule mechanically: the builtins namespace
        # stays out of modules (lib equivalents exist for everything modules
        # need). Standalone files that evaluate without nixpkgs —
        # secrets.nix, keys.nix, the plain-data lib/ files — are exempt by
        # scope. The bracketed pattern keeps the check from matching its
        # own source.
        nix-style = pkgs.runCommand "nix-style-check" { } ''
          if grep -rn 'builtins[.]' ${self}/modules ${self}/options ${self}/hosts --include='*.nix'; then
            echo 'builtins usage in a module - use the lib equivalent (AGENTS.md, Nix style)' >&2
            exit 1
          fi
          touch $out
        '';

        nixfmt = pkgs.runCommand "nixfmt-check" { nativeBuildInputs = [ pkgs.nixfmt-rfc-style ]; } ''
          find ${self} -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';

        # A tracked secret without a rule is an error (it can't be rekeyed
        # and nothing owns it). A rule without its file is only a warning:
        # the documented workflow adds the rule before creating the secret
        # (bootstrap-gated secrets sit in that state until provisioned).
        secrets-rules =
          if unruled != [ ] then
            throw (
              "tracked .age files without a secrets.nix rule:\n"
              + lib.strings.concatMapStrings (path: "  ${path}\n") unruled
            )
          else if dangling != [ ] then
            lib.warn "secrets.nix rules awaiting their .age file: ${toString dangling}" (
              pkgs.runCommand "secrets-rules-ok" { } "touch $out"
            )
          else
            pkgs.runCommand "secrets-rules-ok" { } "touch $out";
      };
    };
}
