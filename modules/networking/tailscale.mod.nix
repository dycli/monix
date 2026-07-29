# Tailscale aspect. Auto-imported into every host and enabled by default.
# Opt out per host with `services.tailscale.enable = lib.modules.mkForce false;`.
{
  flake.nixosModules.tailscale =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkDefault mkIf mkMerge;
    in
    {
      config = mkMerge [
        { services.tailscale.enable = mkDefault true; }
        (mkIf config.services.tailscale.enable {
          services.tailscale.useRoutingFeatures = mkDefault "client";

          # Tailscale SSH: tailscaled answers SSH over the tailnet itself,
          # authenticating by tailnet identity — no per-device authorized
          # keys. Who may SSH where is governed by the tailnet policy's
          # `ssh` section, not here. Plain sshd still runs as a
          # belt-and-suspenders path (and for non-tailnet desktop access).
          # `set` flags (unlike `up` flags) apply on every activation, with
          # or without an auth key.
          #
          # OFF on the host that runs the caged seat: a Tailscale SSH
          # session runs under tailscaled's cgroup, so it would bypass the
          # seat's slice fence entirely (cockpit.mod.nix documents this),
          # and whether anyone may land as `bridge` would rest on a tailnet
          # ACL that lives outside this repo. A local boundary should not
          # depend on remote policy. Plain sshd already serves the tailnet
          # there, so nothing is lost but the bypass.
          services.tailscale.extraSetFlags = singleton (
            if config.cockpit.enable then "--ssh=false" else "--ssh"
          );

          # Trust the tailnet interface so services bound on it are
          # reachable without opening the public firewall.
          networking.firewall.trustedInterfaces = singleton "tailscale0";
          networking.firewall.checkReversePath = mkDefault "loose";
        })
      ];
    };
}
