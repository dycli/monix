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
      inherit (lib.strings) hasSuffix removePrefix;

      crate =
        path: extras:
        pkgs.rustPlatform.buildRustPackage (
          {
            pname = "${builtins.baseNameOf path}-check";
            version = "0";
            src = "${self}/${path}";
            cargoLock.lockFile = "${self}/${path}/Cargo.lock";
          }
          // extras
        );

      # Every tracked *.age must have a rule in secrets.nix and every rule
      # must point at a tracked file — a new secret can't silently lack an
      # owner, and a deleted one can't leave a dangling rule.
      ruled = builtins.attrNames (import "${self}/secrets.nix");
      tracked =
        builtins.filter (path: hasSuffix ".age" path) (
          map (path: removePrefix "${self}/" (toString path)) (
            lib.filesystem.listFilesRecursive self
          )
        );
      unruled = builtins.filter (path: !builtins.elem path ruled) tracked;
      dangling = builtins.filter (path: !builtins.elem path tracked) ruled;
    in
    {
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
