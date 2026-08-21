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
      kestrelHypridle = pkgs.writeShellApplication {
        name = "kestrel-hypridle";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.hypridle
          pkgs.jq
          pkgs.power-profiles-daemon
        ];
        text = ''
          state_root="''${XDG_STATE_HOME:-$HOME/.local/state}"
          runtime_root="''${XDG_RUNTIME_DIR:-/tmp}/kestrel"
          settings_path="$state_root/kestrel/power-settings.json"
          config_path="$runtime_root/hypridle.conf"

          policy_key="default"
          battery_path="$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' -print -quit)"
          if [[ -n "$battery_path" ]]; then
            profile="$(powerprofilesctl get 2>/dev/null || true)"
            case "$profile" in
              power-saver | balanced | performance) policy_key="$profile" ;;
            esac
          fi

          read_minutes() {
            local field="$1"
            local fallback="$2"
            local minimum="$3"
            local maximum="$4"
            local candidate=""
            if [[ -r "$settings_path" ]]; then
              candidate="$(jq -r --arg policy "$policy_key" --arg field "$field" \
                'if .policies[$policy][$field] == null then empty else .policies[$policy][$field] end' \
                "$settings_path" 2>/dev/null || true)"
            fi
            if [[ "$candidate" =~ ^[0-9]+$ ]] \
              && (( candidate >= minimum && candidate <= maximum )); then
              printf '%s' "$candidate"
            else
              printf '%s' "$fallback"
            fi
          }

          read_enabled() {
            local field="$1"
            local fallback="$2"
            local candidate=""
            if [[ -r "$settings_path" ]]; then
              candidate="$(jq -r --arg policy "$policy_key" --arg field "$field" \
                'if .policies[$policy][$field] == null then empty else .policies[$policy][$field] end' \
                "$settings_path" 2>/dev/null || true)"
            fi
            if [[ "$candidate" == "true" || "$candidate" == "false" ]]; then
              printf '%s' "$candidate"
            else
              printf '%s' "$fallback"
            fi
          }

          lock_enabled="$(read_enabled 'lockEnabled' false)"
          lock_minutes="$(read_minutes 'lockMinutes' 5 1 60)"
          display_enabled="$(read_enabled 'displayOffEnabled' false)"
          display_minutes="$(read_minutes 'displayOffMinutes' 7 1 60)"
          suspend_enabled="$(read_enabled 'suspendEnabled' true)"
          suspend_minutes="$(read_minutes 'suspendMinutes' 10 5 120)"

          mkdir -p "$runtime_root"
          {
            printf '%s\n' \
              'general {' \
              '    lock_cmd = ${getExe' pkgs.procps "pidof"} hyprlock || ${getExe pkgs.hyprlock}' \
              '    before_sleep_cmd = ${getExe' pkgs.systemd "loginctl"} lock-session' \
              '    after_sleep_cmd = ${getExe' pkgs.hyprland "hyprctl"} dispatch dpms on' \
              '    ignore_dbus_inhibit = false' \
              '    ignore_systemd_inhibit = false' \
              '    ignore_wayland_inhibit = false' \
              '    inhibit_sleep = 3' \
              '}'

            if [[ "$lock_enabled" == "true" ]]; then
              printf 'listener {\n    timeout = %s\n    on-timeout = %s lock-session\n}\n' \
                "$((lock_minutes * 60))" '${getExe' pkgs.systemd "loginctl"}'
            fi
            if [[ "$display_enabled" == "true" ]]; then
              printf 'listener {\n    timeout = %s\n    on-timeout = %s dispatch dpms off\n    on-resume = %s dispatch dpms on\n}\n' \
                "$((display_minutes * 60))" '${getExe' pkgs.hyprland "hyprctl"}' \
                '${getExe' pkgs.hyprland "hyprctl"}'
            fi
            if [[ "$suspend_enabled" == "true" ]]; then
              printf 'listener {\n    timeout = %s\n    on-timeout = %s suspend\n}\n' \
                "$((suspend_minutes * 60))" '${getExe' pkgs.systemd "systemctl"}'
            fi
          } > "$config_path"

          exec hypridle --config "$config_path"
        '';
      };
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
              font_size = 96;
              position = "0, 200";
              halign = "center";
              valign = "center";
            }
            {
              monitor = "";
              text = "cmd[update:60000] date '+%A, %B %-d'";
              color = "rgba(255, 255, 255, 1.0)";
              font_family = "ComicCodeLigatures Nerd Font";
              font_size = 28;
              position = "0, 110";
              halign = "center";
              valign = "center";
            }
          ];

          input-field = [
            {
              monitor = "";
              size = "480, 84";
              position = "0, -40";
              halign = "center";
              valign = "center";
              outline_thickness = 1;
              rounding = 16;
              outer_color = "rgba(255, 255, 255, 0.8)";
              inner_color = "rgba(15, 15, 15, 0.7)";
              font_color = "rgba(255, 255, 255, 1.0)";
              font_family = "ComicCodeLigatures Nerd Font";
              font_size = 24;
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
        settings = { };
      };
      systemd.user.services.hypridle.Service.ExecStart =
        lib.mkForce "${kestrelHypridle}/bin/kestrel-hypridle";
    };
}
