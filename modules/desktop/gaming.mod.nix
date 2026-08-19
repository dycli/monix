# Gaming: Steam with Proton-GE, gamescope, and the game launchers. A gaming
# host is a desktop, so this rides alongside the desktop bundle.
{ self, ... }:
{
  flake.nixosModules.gaming =
    { pkgs, lib, ... }:
    {
      programs.steam.enable = true;
      programs.steam.extraCompatPackages = lib.lists.singleton pkgs.proton-ge-bin;
      programs.gamescope.enable = true;

      unfreePackages = [
        "steam"
        "steam-unwrapped"
      ];

      # Prism pins the Minecraft client to the water server's version.
      environment.systemPackages = [
        pkgs.dolphin-emu
        pkgs.pcsx2
        pkgs.prismlauncher
        pkgs.heroic
      ];
    };
}
