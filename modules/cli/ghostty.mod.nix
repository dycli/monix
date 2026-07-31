# Terminal. font-family is CaskaydiaMono Nerd Font (installed by
# fonts.mod.nix); ghostty uses its default theme.
{
  # Every host carries ghostty's terminfo so TERM=xterm-ghostty works over
  # SSH; without it tmux and less fail with "missing or unsuitable
  # terminal".
  flake.nixosModules.ghostty-terminfo =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.ghostty.terminfo ];
    };

  flake.homeModules.ghostty =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf mkForce;
    in
    {
      config = mkIf osConfig.isDesktop {
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
            # Low enough for the compositor's blur to actually read as
            # frost behind the terminal; at 0.95 it was invisible.
            # Fully transparent: the background is the compositor's blur,
            # darkened by the blur brightness setting.
            background-opacity = 0;
            window-decoration = "none";

            font-family = "CaskaydiaMono Nerd Font";
            font-size = 10;

            keybind = [ "ctrl+k=reset" ];
          };

          # Daemon flags must not live in the config file, which every
          # plain `ghostty` invocation also reads: initial-window=false
          # there suppresses windows for normal launches. They belong on
          # the daemon's ExecStart, hence upstream's unit.
        };
      };
    };
}
