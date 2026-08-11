# Terminal emulator. The font it names is installed by fonts.mod.nix.
{ self, ... }:
{
  # Every host carries ghostty's terminfo so TERM=xterm-ghostty works over SSH;
  # without it tmux and less fail with "missing or unsuitable terminal".
  flake.nixosModules.default = self.nixosModules.ghostty-terminfo;
  flake.nixosModules.ghostty-terminfo =
    { pkgs, lib, ... }:
    {
      environment.systemPackages = lib.lists.singleton pkgs.ghostty.terminfo;
    };

  flake.homeModules.desktop = self.homeModules.ghostty;

  flake.homeModules.ghostty =
    {
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkForce;
    in
    {
      # Upstream's onChange hook validates the config while the user unit
      # reloads via SIGUSR2; during activation that signal can land on the
      # short-lived validate process and fail activation with exit 140.
      xdg.configFile."ghostty/config".onChange = mkForce ''
        ${getExe' pkgs.systemd "systemctl"} --user try-reload-or-restart app-com.mitchellh.ghostty.service 2>/dev/null || true
      '';

      programs.ghostty = {
        enable = true;

        settings = {
          window-padding-x = 14;
          window-padding-y = 14;
          # Low enough that the compositor's blur still reads as frost; the
          # hyprland window rule thins it further on unfocused terminals.
          background-opacity = 0.7;
          window-decoration = "none";

          font-family = "ComicCodeLigatures Nerd Font";
          font-size = 9;

          # Hyprland sends Super+C/V as Ctrl+Insert/Shift+Insert, and the
          # default for Shift+Insert pastes the primary selection instead.
          keybind = [
            "ctrl+k=reset"
            "ctrl+insert=copy_to_clipboard"
            "shift+insert=paste_from_clipboard"
          ];
        };

        # Daemon-only flags such as initial-window=false belong on the daemon
        # unit's ExecStart; every plain `ghostty` invocation reads settings.
      };
    };
}
