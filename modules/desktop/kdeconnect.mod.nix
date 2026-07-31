# KDE Connect: phone <-> desktop pairing (notifications, clipboard, file
# transfer, media control). Not in the config-less package bundles because it
# carries real configuration: the NixOS module opens its LAN discovery/transfer
# ports (1714-1764 TCP+UDP) — acceptable on desktops, whose firewalls already
# allow LAN service ports, and kept off servers by desktop-bundle membership,
# so fw0's zero-inbound posture is untouched.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.kdeconnect;
  flake.nixosModules.kdeconnect = {
    programs.kdeconnect.enable = true;
  };

  # The user-session half: kdeconnectd plus the tray indicator (DMS renders
  # tray items via StatusNotifier, which is what the indicator speaks).
  flake.homeModules.desktop = self.homeModules.kdeconnect;
  flake.homeModules.kdeconnect = {
    services.kdeconnect = {
      enable = true;
      indicator = true;
    };
  };
}
