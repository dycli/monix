# CUPS printing with mDNS discovery on every desktop.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.printing;
  flake.nixosModules.printing =
    {
      pkgs,
      ...
    }:
    {
      services.printing = {
        enable = true;
        drivers = [
          pkgs.cups-filters
          pkgs.hplip
        ];
      };

      services.avahi = {
        enable = true;
        nssmdns4 = true;
        openFirewall = true;
      };
    };
}
