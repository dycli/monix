{
  flake.nixosModules.networking =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
    in
    {
      # firewall.enable is left to its NixOS default (true); nftables is
      # NOT the default backend, so that one is a real setting.
      networking.nftables.enable = mkDefault true;

      # Servers configure their uplink in their host module.
      networking.networkmanager.enable = mkIf config.isDesktop true;
      services.resolved.enable = mkIf config.isDesktop true;
    };
}
