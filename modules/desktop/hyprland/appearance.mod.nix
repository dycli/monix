# Hyprland appearance and layout: borders, blur, rounding, layout
# behaviour, window and layer rules. Plugin-owned looks (the hyprbars
# Platinum theme) live in plugins.mod.nix — plugin config cannot run on
# the first config pass.
{
  flake.homeModules.hyprland = {
    wayland.windowManager.hyprland.settings = {
      config = {
        general = {
          gaps_in = 0;
          gaps_out = 0;
          border_size = 2;

          # Bar greys, so the border reads as one frame with the
          # titlebar. With bar_precedence_over_border the top border
          # segment lies against the bar and vanishes into it —
          # visible border only on left/right/bottom.
          col.active_border = "rgb(cccccc)";
          col.inactive_border = "rgb(dddddd)";

          resize_on_border = false;
          allow_tearing = false;
          layout = "scrolling";
          no_focus_fallback = true;
        };

        decoration = {
          rounding = 2;

          shadow.enabled = false;

          # Deep gaussian-style frost: three passes over the default
          # size-8 kernel. Only deviations from the pinned v0.56.0
          # defaults (config/values/ConfigValues.cpp) are stated —
          # enabled, new_optimizations and ignore_opacity are already
          # true, and size/noise/contrast/vibrancy sit at their tuned
          # defaults.
          blur = {
            passes = 3;
            # Default 1; darkened so text stays legible on the glass.
            brightness = 0.7;
            popups = true;
          };
        };

        animations.enabled = false;

        dwindle = {
          preserve_split = true;
          force_split = 2;
        };

        master.new_status = "master";

        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
        };

        cursor = {
          inactive_timeout = 5;
        };

        xwayland.force_zero_scaling = true;

        ecosystem.no_update_news = true;
      };

      window_rule = [
        {
          match.class = ".*";
          suppress_event = "maximize";
        }
        {
          match.class = "^org.pulseaudio.pavucontrol$";
          float = true;
        }
        {
          match.class = "^(steam)$";
          float = true;
        }
        {
          match.class = ".*";
          opacity = "1 0.9";
        }
        {
          match.class = "brave-browser";
          opacity = "1 1";
        }
        {
          match.class = "^(steam)$";
          opacity = "1 1";
        }
        {
          # Fixes dragging issues under XWayland.
          match = {
            class = "^$";
            title = "^$";
            xwayland = true;
            float = true;
            fullscreen = false;
            pin = false;
          };
          no_focus = true;
        }
      ];

      layer_rule = [
        {
          match.namespace = "^(dms)$";
          no_anim = true;
        }
      ];
    };
  };
}
