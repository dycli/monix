{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.networking;
  flake.nixosModules.networking =
    { lib, ... }:
    {
      # firewall.enable is left to its NixOS default (true); nftables is
      # NOT the default backend, so that one is a real setting.
      networking.nftables.enable = lib.modules.mkDefault true;
    };

  # Servers configure their uplink in their host module.
  flake.nixosModules.desktop = {
    networking.networkmanager.enable = true;
    services.resolved.enable = true;
  };
}
