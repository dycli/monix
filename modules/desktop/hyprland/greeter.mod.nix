# Login after logout. LUKS gates cold boots, so the desktop itself autologs in.
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
          # greetd does not consume displayManager.autoLogin itself. Its
          # initial session runs once at service start; after logout, the
          # interactive default session below takes over.
          initial_session = {
            command = "${lib.meta.getExe pkgs.uwsm} start -F -D Hyprland -- ${lib.meta.getExe' pkgs.hyprland "start-hyprland"}";
            user = config.primaryUser;
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
