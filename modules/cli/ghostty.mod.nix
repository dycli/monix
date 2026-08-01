# Terminal. font-family is Comic Code (decrypted and installed by
# fonts.mod.nix); ghostty uses its default theme.
{ self, ... }:
{
  # Every host carries ghostty's terminfo so TERM=xterm-ghostty works over
  # SSH; without it tmux and less fail with "missing or unsuitable
  # terminal".
  flake.nixosModules.default = self.nixosModules.ghostty-terminfo;
  flake.nixosModules.ghostty-terminfo =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.ghostty.terminfo ];
    };

  flake.homeModules.desktop = self.homeModules.ghostty;

  flake.homeModules.ghostty =
    {
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkForce;
    in
    {
      # Upstream's onChange hook runs ghostty +validate-config, and the
      # user unit reloads via SIGUSR2. During activation that signal can
      # land on the short-lived validate process and kill the activation
      # with exit 140. The config is Nix-generated, so this replaces the
      # hook with a non-fatal reload.
      xdg.configFile."ghostty/config".onChange = mkForce ''
        ${pkgs.systemd}/bin/systemctl --user try-reload-or-restart app-com.mitchellh.ghostty.service 2>/dev/null || true
      '';

      programs.ghostty = {
        enable = true;

        settings = {
          # Terminal windows only; the login shell stays bash, since
          # tools that shell out via $SHELL break under nushell.
          command = lib.meta.getExe pkgs.nushell;

          window-padding-x = 14;
          window-padding-y = 14;
          # A dark tint over the compositor's glass, low enough that the
          # blur still reads as frost (at 0.95 it was invisible); the
          # hyprland rule thins it on unfocused terminals.
          background-opacity = 0.7;
          window-decoration = "none";

          font-family = "ComicCodeLigatures Nerd Font";
          font-size = 9;

          keybind = [ "ctrl+k=reset" ];
        };

        # Daemon flags must not live in the config file, which every
        # plain `ghostty` invocation also reads: initial-window=false
        # there suppresses windows for normal launches. They belong on
        # the daemon's ExecStart, hence upstream's unit.
      };
    };
}
