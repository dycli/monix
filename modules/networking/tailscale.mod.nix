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
          # DO NOT DISABLE THIS. It was turned off on the cockpit host on
          # 2026-07-30 because a Tailscale SSH session runs under
          # tailscaled's cgroup and so escapes the seat's slice fence. That
          # reasoning was wrong twice over: the escape it prevents is a
          # seat-reach question, which this ship's security doctrine
          # explicitly ACCEPTS as inherent, and Tailscale SSH is how the
          # captain reaches every machine. With it enabled tailscaled
          # answers port 22 for tailnet peers, so `ssh max@fw0` was never
          # touching sshd — disabling it locked him out of his own server
          # mid-activation, from the very session running the switch.
          # If bridge-specific SSH ever needs restricting, do it in the
          # tailnet ACL, not by removing the mechanism.
          services.tailscale.extraSetFlags = [ "--ssh" ];

          # Trust the tailnet interface so services bound on it are
          # reachable without opening the public firewall.
          networking.firewall.trustedInterfaces = singleton "tailscale0";
          networking.firewall.checkReversePath = mkDefault "loose";
        })
      ];
    };
}
