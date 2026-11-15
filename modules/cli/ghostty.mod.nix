# Terminal emulator. The font it names is installed by fonts.mod.nix.
{ self, lib, ... }:
{
  # Every host carries ghostty's terminfo so TERM=xterm-ghostty works over SSH;
  # without it tmux and less fail with "missing or unsuitable terminal".
  flake.nixosModules.default = self.nixosModules.ghostty-terminfo;
  flake.nixosModules.ghostty-terminfo =
    { pkgs, lib, ... }:
    {
      environment.systemPackages = lib.lists.singleton pkgs.ghostty.terminfo;
    };

  # A Darwin host may be shared, so only the primary user's profile carries it.
  # nixpkgs builds Ghostty from source for Linux only; ghostty-bin is the
  # upstream macOS release.
  flake.darwinModules.default = self.darwinModules.ghostty-terminfo-darwin;
  flake.darwinModules.ghostty-terminfo-darwin =
    { config, pkgs, ... }:
    {
      home-manager.users.${config.primaryUser}.home.packages =
        lib.lists.singleton pkgs.ghostty-bin.terminfo;
    };

  flake.homeModules.desktop = self.homeModules.ghostty;
  flake.homeModules.ghostty = {
    programs.ghostty = {
      enable = true;

      settings = {
        window-padding-x = 14;
        window-padding-y = 14;
        confirm-close-surface = false;
      };

      # Daemon-only flags such as initial-window=false belong on the daemon
      # unit's ExecStart; every plain `ghostty` invocation reads settings.
    };
  };

  # Linux only: the Hyprland session's look and keys, and the font
  # fonts.mod.nix installs.
  flake.nixosModules.desktop = self.nixosModules.ghostty-linux;
  flake.homeModules.ghostty-linux =
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

      programs.ghostty.settings = {
        # Low enough that the compositor's blur still reads as frost; the
        # hyprland window rule thins it further on unfocused terminals.
        background-opacity = 0.7;
        # Ghostty 1.4 speaks ext-background-effect, which makes blur the
        # client's choice: left off, Hyprland skips its own blur here too.
        background-blur = true;
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
    };

  flake.darwinModules.desktop = self.darwinModules.ghostty-darwin;
  flake.darwinModules.ghostty-darwin =
    { config, pkgs, ... }:
    {
      home-manager.users.${config.primaryUser}.programs.ghostty = {
        package = pkgs.ghostty-bin;

        settings = {
          macos-titlebar-style = "hidden";
          # Option is Alt in the terminal, as on Linux; the Option chords
          # hammerspoon.mod.nix binds never reach it.
          macos-option-as-alt = true;
          # The app moves with the nixpkgs lock; an update in place would be
          # replaced at the next switch.
          auto-update = "off";
        };
      };
    };
}
