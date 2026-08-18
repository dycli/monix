# Hyprland appearance and layout: borders, blur, rounding, layout behaviour,
# window and layer rules. Plugin-owned looks live in plugins.mod.nix.
{
  flake.homeModules.hyprland =
    { lib, ... }:
    {
      wayland.windowManager.hyprland.settings = {
        config = {
          general = {
            gaps_in = 0;
            gaps_out = 0;
            border_size = 2;

            # Tracks the hyprbars greys: under bar_precedence_over_border the
            # top border segment lies against the bar and vanishes into it.
            col.active_border = "rgb(cccccc)";
            col.inactive_border = "rgb(dddddd)";

            resize_on_border = true;
            allow_tearing = false;
            layout = "hy3";
            no_focus_fallback = true;
          };

          decoration = {
            rounding = 2;

            shadow.enabled = false;

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
            match.class = "^com[.]mitchellh[.]ghostty[.]floating$";
            float = true;
          }
          {
            match.class = "^com[.]mitchellh[.]ghostty([.]floating)?$";
            opacity = "1 0.9";
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
            match.namespace = "^(kestrel:bar)$";
            blur_popups = true;
          }
        ];
      };
    };
}
