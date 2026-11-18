{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.networking;
  flake.nixosModules.networking =
    { lib, ... }:
    {
      # firewall.enable is left to its NixOS default (true); nftables is
      # NOT the default backend, so that one is a real setting.
      networking.nftables.enable = lib.modules.mkDefault true;

      # chrony rather than timesyncd: it weighs several sources at once,
      # rejects one that disagrees, and speaks NTS. Apple's stratum-1
      # servers and Cloudflare's NTS-authenticated ones are the sources;
      # two pool servers make a third voice so a bad source is outvoted.
      # enableNTS stays off because it would demand NTS of every server,
      # and Apple has none; Cloudflare's line asks for it alone.
      services.chrony = {
        enable = lib.modules.mkDefault true;
        servers = [ "time.apple.com" ];
        extraConfig = ''
          server time.cloudflare.com iburst nts
          ntsdumpdir /var/lib/chrony
          pool 2.nixos.pool.ntp.org iburst maxsources 2
        '';
      };
    };

  # Servers configure their uplink in their host module.
  flake.nixosModules.desktop = {
    networking.networkmanager.enable = true;
    services.resolved.enable = true;
  };
}
