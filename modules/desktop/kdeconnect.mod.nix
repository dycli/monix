# KDE Connect: phone/desktop pairing for notifications, clipboard, file
# transfer and media control. The NixOS module opens LAN discovery and transfer
# ports 1714-1764 TCP+UDP, so this belongs to the desktop bundle only and must
# not reach servers.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.kdeconnect;
  flake.nixosModules.kdeconnect = {
    programs.kdeconnect.enable = true;
  };

  flake.homeModules.desktop = self.homeModules.kdeconnect;
  flake.homeModules.kdeconnect = {
    services.kdeconnect = {
      enable = true;
      indicator = true;
    };
  };
}
