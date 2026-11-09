# The flake's checks: each crate built with its tests and clippy, every
# host's system build (host-<name>), rustfmt, nixfmt, the nix-style grep and
# the agenix rulebook; atlas.mod.nix and seat/libri-deploy.mod.nix add their
# own. The crate builds omit the deployment environment the service modules
# bake in, so they are test gates, not the production binaries.
{ self, lib, ... }:
{
  systems = lib.lists.singleton "x86_64-linux";

  perSystem =
    { pkgs, lib, ... }:
    let
      inherit (lib.attrsets) attrNames attrValues mapAttrs;
      inherit (lib.lists) elem filter singleton;
      inherit (lib.strings) hasSuffix removePrefix;
      inherit (lib.trivial) warn;

      # Check name → crate directory and the tools its tests shell out to.
      crates = {
        endgrain.path = "modules/homelab/endgrain";
        frame.path = "modules/homelab/frame";
        money.path = "modules/homelab/money";
      };
      cratePaths = attrValues crates |> map (crate: crate.path);

      # Every tracked .age needs a rule, and every rule a tracked file.
      ruled = attrNames (import "${self}/agenix-rules.nix");
      tracked =
        lib.filesystem.listFilesRecursive self
        |> map (path: removePrefix "${self}/" (toString path))
        |> filter (path: hasSuffix ".age" path);
      unruled = filter (path: !elem path ruled) tracked;
      dangling = filter (path: !elem path tracked) ruled;
    in
    {
      formatter = pkgs.nixfmt;

      checks =
        (
          crates
          |> mapAttrs (
            _: crate:
            lib.ship.rustTool pkgs {
              # A path, not "${self}/…": it copies the crate on its own, so the
              # check is cached by the crate's content and a commit elsewhere
              # doesn't rebuild every crate.
              src = ../. + "/${crate.path}";
              check = true;
              nativeCheckInputs = crate.tools or [ ];
            }
          )
        )
        # Every host builds, so a green check means the deploy builds too.
        // (
          self.nixosConfigurations
          |> lib.attrsets.mapAttrs' (
            name: host: lib.attrsets.nameValuePair "host-${name}" host.config.system.build.toplevel
          )
        )
        // {
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
            if grep -rn 'builtins[.]' ${self}/modules ${self}/options ${self}/hosts ${self}/lib --include='*.nix'; then
              echo 'builtins usage in a module - use the lib equivalent (AGENTS.md, Nix style)' >&2
              exit 1
            fi
            if grep -rn 'with lib[.]' ${self}/modules ${self}/options ${self}/hosts ${self}/lib --include='*.nix'; then
              echo 'with lib usage in a module - inherit from the full lib path (AGENTS.md, Nix style)' >&2
              exit 1
            fi
            touch $out
          '';

          nixfmt = pkgs.runCommand "nixfmt-check" { nativeBuildInputs = singleton pkgs.nixfmt; } ''
            find ${self} -name '*.nix' -exec nixfmt --check {} +
            touch $out
          '';

          # A tracked secret without a rule cannot be rekeyed. A rule without
          # its file is only a warning: the rule precedes the secret.
          secrets-rules =
            if unruled != [ ] then
              throw (
                "tracked .age files without an agenix-rules.nix rule:\n"
                + lib.strings.concatMapStrings (path: "  ${path}\n") unruled
              )
            else if dangling != [ ] then
              warn "agenix-rules.nix rules awaiting their .age file: ${toString dangling}" (
                pkgs.runCommand "secrets-rules-ok" { } "touch $out"
              )
            else
              pkgs.runCommand "secrets-rules-ok" { } "touch $out";
        };
    };
}
