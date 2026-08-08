# Hyprland input: keyboard, touchpad, and touch gestures.
{
  flake.homeModules.hyprland =
    { lib, ... }:
    let
      inherit (lib.generators) mkLuaInline;
    in
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
          # Drags the scrolling layout's column tape, niri-style; snaps
          # to the grid on release. Inert under other layouts, so the
          # workspace swipe moves to four fingers (displacing the resize
          # gesture, which SUPER+right-drag still covers).
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
          # Closures, not bare references: hl.plugin.gloview is nil
          # during the first config pass (plugins load after it), so
          # indexing must wait until the gesture actually fires.
          {
            fingers = 3;
            direction = "up";
            action = mkLuaInline "function() hl.plugin.gloview.open() end";
          }
          {
            fingers = 3;
            direction = "down";
            action = mkLuaInline "function() hl.plugin.gloview.close() end";
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
