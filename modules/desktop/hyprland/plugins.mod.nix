# Hyprland plugins: gloview (workspace overview) and hyprbars
# (titlebars), plus all plugin-coupled configuration. Hyprland comes
# from nixpkgs; the gloview input is plugin source only.
#
# A store-path change here (patch add/remove, version bump) makes the
# next switch live-unload and reload that plugin inside the running
# compositor — a fragile path upstream — so prefer re-logging in after
# such a switch rather than trusting the swap.
{ inputs, ... }:
{
  flake.homeModules.hyprland =
    { lib, pkgs, ... }:
    {
      wayland.windowManager.hyprland = {
        # gloview (Mission Control-style overview, on the SUPER+O bind),
        # compiled here against this pin's hyprland so the plugin ABI
        # matches the running compositor by construction.
        plugins = [
          (pkgs.hyprlandPlugins.mkHyprlandPlugin {
            pluginName = "gloview";
            version = "0.3.0";
            src = inputs.gloview;
            nativeBuildInputs = [
              pkgs.cmake
              pkgs.pkg-config
            ];
            # Lua for the gloview.* config functions; luajit is what
            # hyprland itself links.
            buildInputs = [ pkgs.luajit ];
            # The build emits gloview.so; home-manager's plugins option
            # loads lib<name>.so.
            postInstall = ''ln -sf gloview.so "$out/lib/libgloview.so"'';

            meta = {
              description = "macOS Mission Control-style overview for Hyprland";
              homepage = "https://github.com/fedsfarm/gloview";
              license = lib.licenses.gpl3Plus;
            };
          })
          # Titlebars. Safe from nixpkgs unlike gloview: hyprlandPlugins
          # is built against the same hyprland pin, so the ABI matches by
          # construction.
          pkgs.hyprlandPlugins.hyprbars
        ];

        # All plugin-coupled config lives in these guarded blocks, not
        # in settings: hl.plugin.load only registers a path — the .so
        # loads after the config's first execution, so on a fresh
        # compositor start hl.plugin.* is nil for the whole first pass
        # (indexing it aborts the config; plugin config values and
        # hyprbars:* rule effects are unknown and error softly). The
        # guards keep pass one clean; hyprbars' init then calls
        # reloadConfig and the second pass applies these for real.
        extraConfig = ''
          if hl.plugin.gloview then
            -- Roughly half the plugin's stock timings; snappy but still
            -- spatial. Selection nav on vim keys plus the arrows — the
            -- key lists replace the defaults, so both are named. O
            -- everywhere TAB was: the toggle bind is SUPER+O and falls
            -- through to close, so the workspace keys move off the tab
            -- defaults to match.
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
            -- Dressed like Mac OS 8/9 Platinum. Greys are pixel-sampled
            -- from a pristine OS 9 screenshot (guidebookgallery.org
            -- desktop/full): active bar base CCCCCC (the pinstripes,
            -- FFFFFF/777777, are beyond a solid fill), inactive DDDDDD
            -- with 777777 title in the focus rule below. Title centered
            -- (the default) and black, bold Noto Sans standing in for
            -- Charcoal. Opaque bar, so no blur to join. The border
            -- wraps bar+window as one unit (precedence), so its top
            -- segment lies against the like-colored bar and disappears
            -- (the border greys in appearance.mod.nix track the bar).
            -- One side for all buttons (no per-button alignment
            -- exists); close-on-left is the authentic OS 9 corner.
            hl.config({
              plugin = {
                hyprbars = {
                  bar_height = 25,
                  bar_color = "rgb(cccccc)",
                  col = { text = "rgb(000000)" },
                  bar_text_weight = "bold",
                  bar_text_font = "Noto Sans",
                  bar_precedence_over_border = true,
                  bar_buttons_alignment = "left",
                },
              },
            })

            -- Platinum inactive titlebar. focus is a dynamic matcher —
            -- both windows re-run rules on every focus change and
            -- hyprbars repaints on rule updates, so this flips live.
            -- Plugin effects resolve through the dynamic-effect
            -- registry, hence the string keys.
            hl.window_rule({
              match = { focus = false },
              ["hyprbars:bar_color"] = "rgb(dddddd)",
              ["hyprbars:title_color"] = "rgb(777777)",
            })

            -- With left alignment, declaration order reads
            -- left-to-right on screen: close/maximize/float/width-
            -- cycle. Backgroundless: a fully transparent bg_color draws
            -- nothing (hit detection is size-based, unaffected),
            -- leaving bare 222222 glyphs on the bar the way OS 9's
            -- subtle widgets sit. Every field is required (a missing
            -- fg_color is a parse error, not a white default, unlike
            -- the legacy keyword). Actions spawn as shell commands, and
            -- under the Lua config `hyprctl dispatch` wraps hl.dispatch
            -- — it takes these Lua expressions, and legacy syntax like
            -- "dispatch killactive" fails (silently, from a spawn).
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
            -- Cycles the scrolling layout's preset widths, same as the
            -- SUPER+APOSTROPHE bind; no-op under dwindle.
            hl.plugin.hyprbars.add_button({
              bg_color = "rgba(00000000)",
              fg_color = "rgb(222222)",
              size = 20,
              icon = "󰩨",
              action = [=[hyprctl dispatch 'hl.dsp.layout("colresize +conf")']=],
            })
          end
        '';
      };
    };
}
