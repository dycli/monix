# Tailscale aspect. Auto-imported into every host and enabled by default.
# Opt out per host with `services.tailscale.enable = lib.modules.mkForce false;`.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.tailscale;
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

          # tailscaled answers port 22 for tailnet peers, authenticating by
          # tailnet identity; who may connect is governed by the tailnet
          # policy's `ssh` section. Disabling this removes SSH access for
          # anyone without a key in authorized_keys — restrict via the ACL
          # instead. `set` flags apply on every activation, unlike `up`.
          services.tailscale.extraSetFlags = singleton "--ssh";

          # Trust the tailnet interface so services bound on it are
          # reachable without opening the public firewall.
          networking.firewall.trustedInterfaces = singleton "tailscale0";
          networking.firewall.checkReversePath = mkDefault "loose";
        })
      ];
    };
}
