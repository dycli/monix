# "Games": the tailnet launcher at play.su.is full screen in Brave. Its
# own profile keeps the saves apart from everyday browsing and lets it start
# with the autoplay rule lifted: the games are paced by their sound, and a
# gamepad press does not count as the gesture Chromium otherwise waits for.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.play-desktop;
  flake.nixosModules.play-desktop =
    { lib, pkgs, ... }:
    let
      play = pkgs.writeShellScript "play" ''
        exec ${lib.getExe pkgs.brave} \
          --user-data-dir="''${XDG_STATE_HOME:-$HOME/.local/state}/play" \
          --autoplay-policy=no-user-gesture-required \
          --app=https://play.su.is/ --start-fullscreen
      '';
    in
    {
      environment.systemPackages = lib.singleton (
        pkgs.makeDesktopItem {
          name = "play";
          desktopName = "Games";
          comment = "Recompiled games from play.su.is";
          exec = "${play}";
          icon = "applications-games";
          categories = [ "Game" ];
        }
      );
    };
}
