# Hyprland plugins: hyprbars (titlebars) and hy3 (manual tiling), plus all
# plugin-coupled configuration.
#
# A store-path change here makes the next switch live-unload and reload the
# plugin inside the running compositor, which is unreliable upstream; re-log in
# rather than trusting the swap.
{ inputs, ... }:
{
  flake.homeModules.hyprland =
    { pkgs, ... }:
    {
      wayland.windowManager.hyprland = {
        # Built against this pin's hyprland so the plugin ABI matches the
        # running compositor by construction.
        plugins = [
          (pkgs.hyprlandPlugins.hyprbars.overrideAttrs {
            src = inputs.hyprland-plugins + "/hyprbars";
            version = "unstable-2026-09-05";
          })
          (pkgs.hyprlandPlugins.hy3.overrideAttrs {
            src = inputs.hy3;
            version = "unstable-2026-08-23";
          })
        ];

        # Plugin-coupled config belongs in these guarded blocks, not in
        # settings: hl.plugin.load only registers a path and the .so loads
        # after the config's first execution, leaving hl.plugin.* nil for that
        # whole pass. hyprbars' init then calls reloadConfig and the second
        # pass applies these.
        extraConfig = ''
          if hl.plugin.hyprbars then
            -- Button alignment is global; there is no per-button side.
            hl.config({
              plugin = {
                hyprbars = {
                  bar_height = 25,
                  bar_color = "rgb(000000)",
                  bar_title_enabled = false,
                  bar_precedence_over_border = true,
                  bar_buttons_alignment = "left",
                },
              },
            })

            -- Declaration order reads left-to-right on screen. A transparent
            -- bg_color draws no box; hit detection is size-based. Every field
            -- is required. Actions spawn as shell commands, and under the Lua
            -- config `hyprctl dispatch` takes Lua expressions — legacy
            -- dispatcher syntax fails silently.
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(b8b3c2)",
              size = 20,
              icon = "󰖭",
              action = "hyprctl dispatch 'hl.dsp.window.close()'",
            })
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(b8b3c2)",
              size = 20,
              icon = "󰖯",
              action = [=[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']=],
            })
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(b8b3c2)",
              size = 20,
              icon = "󰖲",
              action = "hyprctl dispatch 'hl.dsp.window.float()'",
            })
          end
        '';
      };
    };
}
