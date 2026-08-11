# `nix flake check` builds the crates, runs their tests and verifies the
# agenix rulebook. These builds omit the deployment environment the service
# modules bake in, so they are test gates, not the production binaries.
{ self, lib, ... }:
{
  systems = lib.lists.singleton "x86_64-linux";

  perSystem =
    { pkgs, lib, ... }:
    let
      inherit (lib) baseNameOf;
      inherit (lib.attrsets) attrNames;
      inherit (lib.lists) elem filter singleton;
      inherit (lib.strings) hasSuffix removePrefix;

      crate =
        path: extras:
        pkgs.rustPlatform.buildRustPackage (
          {
            pname = "${baseNameOf path}-check";
            version = "0";
            src = "${self}/${path}";
            cargoLock.lockFile = "${self}/${path}/Cargo.lock";
            # The lint gate lives here, not in the production module builds.
            nativeBuildInputs = singleton pkgs.clippy;
            postCheck = "cargo clippy --all-targets -- -D warnings";
          }
          // extras
        );

      cratePaths = [
        "modules/ai/agent-dispatch"
        "modules/ai/agent-vm"
        "modules/ai/fleet-tool/fleet-cli"
        "modules/ai/memo/memo-cli"
        "modules/homelab/alerts/ship-alert"
      ];

      # Every tracked .age needs a rule, and every rule a tracked file.
      ruled = attrNames (import "${self}/secrets.nix");
      tracked =
        lib.filesystem.listFilesRecursive self
        |> map (path: removePrefix "${self}/" (toString path))
        |> filter (path: hasSuffix ".age" path);
      unruled = filter (path: !elem path ruled) tracked;
      dangling = filter (path: !elem path tracked) ruled;
    in
    {
      formatter = pkgs.nixfmt-rfc-style;

      checks = {
        agent-dispatch = crate "modules/ai/agent-dispatch" { };
        agent-vm = crate "modules/ai/agent-vm" {
          nativeCheckInputs = [
            pkgs.jq
            pkgs.sqlite
          ];
        };
        fleet-cli = crate "modules/ai/fleet-tool/fleet-cli" { };
        memo = crate "modules/ai/memo/memo-cli" { };
        ship-alert = crate "modules/homelab/alerts/ship-alert" { };

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
                # A crate's store copy has no target/, so this find covers
                # exactly src and tests.
                find ${self}/${path} -name '*.rs' \
                  | xargs --no-run-if-empty rustfmt --edition 2024 --check
              '') cratePaths}
              touch $out
            '';

        # The bracketed pattern keeps the check from matching its own source.
        nix-style = pkgs.runCommand "nix-style-check" { } ''
          if grep -rn 'builtins[.]' ${self}/modules ${self}/options ${self}/hosts --include='*.nix'; then
            echo 'builtins usage in a module - use the lib equivalent (AGENTS.md, Nix style)' >&2
            exit 1
          fi
          touch $out
        '';

        nixfmt = pkgs.runCommand "nixfmt-check" { nativeBuildInputs = singleton pkgs.nixfmt-rfc-style; } ''
          find ${self} -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';

        # A tracked secret without a rule cannot be rekeyed. A rule without
        # its file is only a warning: the rule precedes the secret.
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
