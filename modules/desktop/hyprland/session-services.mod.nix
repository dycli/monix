# Native Hyprland session services.
{ self, ... }:
{
  flake.nixosModules.hyprland = {
    # programs.hyprlock lives in Home Manager; PAM still needs a system-side
    # service entry so the lock screen can authenticate the current user.
    security.pam.services.hyprlock = { };
  };

  flake.homeModules.hyprland =
    { lib, pkgs, ... }:
    let
      inherit (lib.meta) getExe getExe';
      wallpaper = ../../../assets/wallpapers/Bierstadt-Among-the-Sierra-Nevada-Mountains.jpg;
    in
    {
      services.hyprpolkitagent.enable = true;

      services.hyprpaper = {
        enable = true;
        systemdTarget = "graphical-session.target";
        settings = {
          splash = false;
          ipc = true;
          wallpaper = [
            {
              monitor = "";
              path = "${wallpaper}";
              fit_mode = "cover";
            }
          ];
        };
      };

      programs.hyprlock = {
        enable = true;
        settings = {
          general = {
            # Negotiate the preferred scale independently per output.
            fractional_scaling = 2;
            hide_cursor = true;
            ignore_empty_input = true;
          };

          background = [
            {
              monitor = "";
              path = "${wallpaper}";
              color = "rgba(15, 15, 15, 1.0)";
              blur_passes = 3;
              blur_size = 8;
              brightness = 0.65;
            }
          ];

          label = [
            {
              monitor = "";
              text = "$TIME";
              color = "rgba(255, 255, 255, 1.0)";
              font_family = "ComicCodeLigatures Nerd Font";
              font_size = 48;
              position = "0, 100";
              halign = "center";
              valign = "center";
            }
            {
              monitor = "";
              text = "cmd[update:60000] date '+%A, %B %-d'";
              color = "rgba(255, 255, 255, 1.0)";
              font_family = "ComicCodeLigatures Nerd Font";
              font_size = 14;
              position = "0, 55";
              halign = "center";
              valign = "center";
            }
          ];

          input-field = [
            {
              monitor = "";
              size = "240, 42";
              position = "0, -20";
              halign = "center";
              valign = "center";
              outline_thickness = 1;
              rounding = 8;
              outer_color = "rgba(255, 255, 255, 0.8)";
              inner_color = "rgba(15, 15, 15, 0.7)";
              font_color = "rgba(255, 255, 255, 1.0)";
              font_family = "ComicCodeLigatures Nerd Font";
              font_size = 12;
              placeholder_text = "Password";
              fail_text = "$FAIL";
              dots_center = true;
              fade_on_empty = false;
            }
          ];
        };
      };

      services.hypridle = {
        enable = true;
        systemdTarget = "graphical-session.target";
        settings = {
          general = {
            lock_cmd = "${getExe' pkgs.procps "pidof"} hyprlock || ${getExe pkgs.hyprlock}";
            before_sleep_cmd = "${getExe' pkgs.systemd "loginctl"} lock-session";
            after_sleep_cmd = "${getExe' pkgs.hyprland "hyprctl"} dispatch dpms on";
            ignore_dbus_inhibit = false;
            ignore_systemd_inhibit = false;
            ignore_wayland_inhibit = false;
            inhibit_sleep = 3;
          };

          listener = [
            {
              timeout = 600;
              on-timeout = "${getExe' pkgs.systemd "systemctl"} suspend";
            }
          ];
        };
      };
    };
}
