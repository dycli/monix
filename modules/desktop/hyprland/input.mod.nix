# Hyprland input: keyboard, touchpad, and touch gestures.
{
  flake.homeModules.hyprland =
    { ... }:
    {
      wayland.windowManager.hyprland.settings = {
        config.input = {
          kb_layout = "us";
          kb_options = "compose:caps";

          follow_mouse = 1;
          sensitivity = 0;
          repeat_rate = 100;
          repeat_delay = 200;

          touchpad = {
            natural_scroll = false;
            clickfinger_behavior = true;
          };
        };

        gesture = [
          # scroll_move drags the scrolling layout's column tape and is inert
          # under other layouts, so the workspace swipe takes four fingers.
          {
            fingers = 3;
            direction = "horizontal";
            action = "scroll_move";
          }
          {
            fingers = 4;
            direction = "horizontal";
            action = "workspace";
          }
          {
            fingers = 3;
            direction = "pinchout";
            action = "float";
            mode = "float";
          }
          {
            fingers = 4;
            direction = "pinchout";
            action = "float";
            mode = "float";
          }
          {
            fingers = 3;
            direction = "pinchin";
            action = "float";
            mode = "tile";
          }
          {
            fingers = 4;
            direction = "pinchin";
            action = "float";
            mode = "tile";
          }
          {
            fingers = 3;
            direction = "swipe";
            mods = "SUPER";
            action = "move";
          }
        ];
      };
    };
}
