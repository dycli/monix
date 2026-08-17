# Hyprland plugins: gloview (workspace overview), hyprbars (titlebars), and hy3
# (manual tiling), plus all plugin-coupled configuration.
#
# A store-path change here makes the next switch live-unload and reload the
# plugin inside the running compositor, which is unreliable upstream; re-log in
# rather than trusting the swap.
{ inputs, ... }:
{
  flake.homeModules.hyprland =
    { lib, pkgs, ... }:
    {
      wayland.windowManager.hyprland = {
        # Built against this pin's hyprland so the plugin ABI matches the
        # running compositor by construction.
        plugins = [
          (pkgs.hyprlandPlugins.mkHyprlandPlugin {
            pluginName = "gloview";
            version = "0.3.0";
            src = inputs.gloview;
            nativeBuildInputs = [
              pkgs.cmake
              pkgs.pkg-config
            ];
            # luajit, matching what hyprland itself links.
            buildInputs = lib.lists.singleton pkgs.luajit;
            # The build emits gloview.so; the plugins option loads lib<name>.so.
            postInstall = ''ln -sf gloview.so "$out/lib/libgloview.so"'';

            meta = {
              description = "macOS Mission Control-style overview for Hyprland";
              homepage = "https://github.com/fedsfarm/gloview";
              license = lib.licenses.gpl3Plus;
            };
          })
          pkgs.hyprlandPlugins.hyprbars
          pkgs.hyprlandPlugins.hy3
        ];

        # Plugin-coupled config belongs in these guarded blocks, not in
        # settings: hl.plugin.load only registers a path and the .so loads
        # after the config's first execution, leaving hl.plugin.* nil for that
        # whole pass. hyprbars' init then calls reloadConfig and the second
        # pass applies these.
        extraConfig = ''
          if hl.plugin.gloview then
            -- Key lists replace the plugin defaults; workspace keys match
            -- the SUPER+O toggle bind.
            hl.config({
              plugin = {
                gloview = {
                  duration = 120,
                  switch_duration = 100,
                  move_duration = 100,

                  key_left = "h left",
                  key_right = "l right",
                  key_up = "k up",
                  key_down = "j down",

                  key_next_workspace = "o",
                  key_prev_workspace = "shift+o",
                  key_activate = "w enter",
                },
              },
            })
          end

          if hl.plugin.hyprbars then
            -- Mac OS 9 Platinum greys. bar_precedence_over_border wraps the
            -- border around bar+window; the like-colored top segment vanishes
            -- into the bar (appearance.mod.nix borders match). Button
            -- alignment is global; there is no per-button side.
            hl.config({
              plugin = {
                hyprbars = {
                  bar_height = 25,
                  bar_color = "rgb(cccccc)",
                  bar_title_enabled = false,
                  bar_precedence_over_border = true,
                  bar_buttons_alignment = "left",
                },
              },
            })

            -- Inactive-window grey; focus rules re-evaluate on every focus
            -- change. Plugin rule effects require the string keys.
            hl.window_rule({
              match = { focus = false },
              ["hyprbars:bar_color"] = "rgb(dddddd)",
            })

            -- Declaration order reads left-to-right on screen. A transparent
            -- bg_color draws no box; hit detection is size-based. Every field
            -- is required. Actions spawn as shell commands, and under the Lua
            -- config `hyprctl dispatch` takes Lua expressions — legacy
            -- dispatcher syntax fails silently.
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(222222)",
              size = 20,
              icon = "󰖭",
              action = "hyprctl dispatch 'hl.dsp.window.close()'",
            })
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(222222)",
              size = 20,
              icon = "󰖯",
              action = [=[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']=],
            })
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(222222)",
              size = 20,
              icon = "󰖲",
              action = "hyprctl dispatch 'hl.dsp.window.float()'",
            })
            -- Width steps work across the available tiled layouts.
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(222222)",
              size = 20,
              icon = "󰅁",
              action = [=[hyprctl dispatch 'hl.dsp.window.resize({ x = -100, y = 0, relative = true })']=],
            })
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(222222)",
              size = 20,
              icon = "󰅂",
              action = [=[hyprctl dispatch 'hl.dsp.window.resize({ x = 100, y = 0, relative = true })']=],
            })
          end
        '';
      };
    };
}
