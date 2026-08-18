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
      services.displayManager.autoLogin = {
        enable = true;
        user = config.primaryUser;
      };

      services.greetd = {
        enable = true;
        settings.default_session = {
          command = "${lib.meta.getExe pkgs.tuigreet} --time --remember --remember-session --sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
          user = "greeter";
        };
      };

      # Kestrel's battery service reads UPower.
      services.upower.enable = true;
    };
}
