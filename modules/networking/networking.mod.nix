{
  flake.nixosModules.networking =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
    in
    {
      networking.firewall.enable = mkDefault true;
      networking.nftables.enable = mkDefault true;

      # Desktops use NetworkManager + systemd-resolved; servers configure
      # their uplink (DHCP or networkd) in their host module.
      networking.networkmanager.enable = mkIf config.isDesktop true;
      services.resolved.enable = mkIf config.isDesktop true;
    };
}
