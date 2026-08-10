# CUPS printing with mDNS discovery. Inert until a host sets
# `services.printing.enable = true`.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.printing;
  flake.nixosModules.printing =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf config.services.printing.enable {
        services.printing.drivers = [
          pkgs.cups-filters
          pkgs.hplip
        ];

        services.avahi = {
          enable = true;
          nssmdns4 = true;
          openFirewall = true;
        };
      };
    };
}
