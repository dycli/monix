# Hyprland's built-in scrolling layout, tuned to behave and look like niri.
#
# Spacing, border width and animations are global options in Hyprland, so the
# niri look is a profile applied only while general.layout is "scrolling"; any
# other layout gets the values from appearance.mod.nix back. The profile
# follows the layout switch itself (config.props_refreshed fires after every
# runtime hl.config), so the layout binds need no knowledge of it.
#
# Targets are niri's defaults (resources/default-config.kdl and
# niri-config/src/animations.rs, checked 2026-11-04).
{
  flake.homeModules.hyprland =
    { config, lib, ... }:
    let
      general = config.wayland.windowManager.hyprland.settings.config.general;
      animationsEnabled = config.wayland.windowManager.hyprland.settings.config.animations.enabled;
      luaBool = b: if b then "true" else "false";
    in
    {
      wayland.windowManager.hyprland.settings.config = {
        scrolling = {
          # niri: a lone column keeps its width instead of filling the output.
          fullscreen_on_one_column = false;
          column_width = 0.5;
          # niri center-focused-column "never": scroll just enough to show it.
          focus_fit_method = 1;
          # niri preset-column-widths; full width is the maximize bind's job.
          explicit_column_widths = "0.333, 0.5, 0.667";
          # niri stops at the first and last column.
          wrap_focus = false;
          wrap_swapcol = false;
        };
      };

      wayland.windowManager.hyprland.extraConfig = ''
        -- niri's springs are critically damped with unit mass, so damping is
        -- 2*sqrt(stiffness). Springs keep their velocity when interrupted,
        -- which is what makes niri's view movement feel continuous.
        hl.curve("niri_view", { type = "spring", stiffness = 800, damping = 56.5685, mass = 1 })
        hl.curve("niri_workspace", { type = "spring", stiffness = 1000, damping = 63.2456, mass = 1 })
        -- niri window-open: 150 ms ease-out-expo; window-close: 150 ms ease-out-quad.
        hl.curve("niri_open", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })
        hl.curve("niri_close", { type = "bezier", points = { { 0.25, 0.46 }, { 0.45, 0.94 } } })

        -- Only the leaves niri animates. The shell's layers, border colours
        -- and focus fades stay instant, as they are with animations off.
        hl.animation({ leaf = "global", enabled = false })
        hl.animation({ leaf = "windowsMove", enabled = true, speed = 1, spring = "niri_view" })
        hl.animation({ leaf = "windowsIn", enabled = true, speed = 1.5, bezier = "niri_open", style = "popin 50%" })
        hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.5, bezier = "niri_close", style = "popin 50%" })
        hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.5, bezier = "niri_open" })
        hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.5, bezier = "niri_close" })
        -- niri stacks workspaces vertically.
        hl.animation({ leaf = "workspaces", enabled = true, speed = 1, spring = "niri_workspace", style = "slidevert" })
        hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 1, spring = "niri_workspace", style = "slidevert" })

        local layout_profiles = {
          -- niri: 16 px gaps between columns and at the output edges (Hyprland
          -- puts gaps_in on each side of a window), 4 px focus ring.
          scrolling = {
            general = { gaps_in = 8, gaps_out = 16, border_size = 4 },
            animations = { enabled = true },
          },
          other = {
            general = {
              gaps_in = ${toString general.gaps_in},
              gaps_out = ${toString general.gaps_out},
              border_size = ${toString general.border_size},
            },
            animations = { enabled = ${luaBool animationsEnabled} },
          },
        }

        -- niri-style binds that exist only while scrolling is the layout, so
        -- under hy3 and dwindle these keys reach applications as before. None
        -- of these keys is bound anywhere else. They live here rather than in
        -- keybinds.mod.nix because they come and go with the profile.
        local function scrolling_message(message)
          return function()
            hl.dispatch(hl.dsp.layout(message))
          end
        end
        local scrolling_binds = {
          { "SUPER + CTRL + LEFT", scrolling_message("swapcol l"), "Move column left" },
          { "SUPER + CTRL + RIGHT", scrolling_message("swapcol r"), "Move column right" },
          { "SUPER + CTRL + C", scrolling_message("center"), "Center column" },
          { "SUPER + SHIFT + mouse_down", scrolling_message("focus r"), "Focus column right" },
          { "SUPER + SHIFT + mouse_up", scrolling_message("focus l"), "Focus column left" },
        }
        -- niri stacks workspaces vertically and switches them with a vertical
        -- swipe. The four-finger horizontal workspace swipe in input.mod.nix
        -- stays as it is in every layout; this adds the vertical direction.
        local scrolling_gesture = { fingers = 4, direction = "vertical", action = "workspace" }

        local function enter_scrolling()
          for _, b in ipairs(scrolling_binds) do
            hl.bind(b[1], b[2], { description = b[3] })
          end
          hl.gesture(scrolling_gesture)
        end

        local function leave_scrolling()
          for _, b in ipairs(scrolling_binds) do
            hl.unbind(b[1])
          end
          hl.gesture({ fingers = 4, direction = "vertical", action = "unset" })
        end

        -- Each Lua state starts from the config file, whose layout is never
        -- scrolling, so "other" is already in force and nothing above is bound.
        local applied_profile = "other"

        hl.on("config.props_refreshed", function()
          local wanted = hl.get_config("general.layout") == "scrolling" and "scrolling" or "other"
          if wanted ~= applied_profile then
            -- Set first: this hl.config schedules another refresh, which
            -- must find nothing left to do.
            applied_profile = wanted
            local profile = layout_profiles[wanted]
            -- niri draws no titlebars. hyprbars is nil until its .so loads.
            if hl.plugin.hyprbars then
              profile.plugin = { hyprbars = { enabled = wanted ~= "scrolling" } }
            end
            hl.config(profile)
            if wanted == "scrolling" then
              enter_scrolling()
            else
              leave_scrolling()
            end
          end
        end)
      '';
    };
}
