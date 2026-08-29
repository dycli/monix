# Graphical login. Desktop hosts may opt into one initial automatic session;
# otherwise tuigreet waits without starting a compositor.
{ self, ... }:
{
  flake.nixosModules.hyprland =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      services.greetd = {
        enable = true;
        settings = {
          # greetd does not consume displayManager.autoLogin itself, so map
          # the standard policy to its one-shot initial session explicitly.
          initial_session = lib.modules.mkIf config.services.displayManager.autoLogin.enable {
            command = "${lib.meta.getExe pkgs.uwsm} start -F -D Hyprland -- ${lib.meta.getExe' pkgs.hyprland "start-hyprland"}";
            user = config.services.displayManager.autoLogin.user;
          };

          default_session = {
            command = "${lib.meta.getExe pkgs.tuigreet} --time --remember --remember-session --sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
            user = "greeter";
          };
        };
      };

      # Kestrel's battery service reads UPower.
      services.upower.enable = true;
    };
}
