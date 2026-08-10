# Hyprland keybinds. Every bind carries a description: the keybinds overlay
# reads them back via `hyprctl binds -j`, Lua being executed rather than parsed.
{
  flake.homeModules.hyprland =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.generators) mkLuaInline;
      inherit (lib.lists) concatMap range;
      inherit (lib.attrsets) recursiveUpdate;
      inherit (lib.meta) getExe;

      # One hl.bind call per element; opts merges over the description.
      mkBind = keys: dispatcherLua: description: opts: {
        _args = [
          keys
          (mkLuaInline dispatcherLua)
          (recursiveUpdate { inherit description; } opts)
        ];
      };

      terminal = getExe config.desktopApps.terminal;
      browser = getExe config.desktopApps.browser;
      messenger = getExe config.desktopApps.messenger;
      passwordManager = getExe config.desktopApps.passwordManager;
      email = getExe config.desktopApps.email;
      inherit (config.desktopApps) editor;
    in
    {
      wayland.windowManager.hyprland.settings.bind = [
        (mkBind "SUPER + RETURN" ''hl.dsp.exec_cmd("${terminal}")'' "Open terminal" { })
        (mkBind "SUPER + BACKSPACE" ''hl.dsp.exec_cmd("dms ipc call powermenu toggle")'' "Power menu" { })
        (mkBind "SUPER + SLASH" ''hl.dsp.exec_cmd("${passwordManager}")'' "Open password manager" { })
        (mkBind "SUPER + C" ''hl.dsp.send_shortcut({ mods = "CTRL", key = "Insert" })''
          "Copy (send Ctrl+Insert to focused window)"
          { }
        )
        (mkBind "SUPER + D" ''hl.dsp.exec_cmd("dms ipc call spotlight toggle")'' "App launcher" { })
        (mkBind "SUPER + E" ''hl.dsp.exec_cmd("${email}")'' "Open email" { })
        (mkBind "SUPER + N" ''hl.dsp.exec_cmd("${terminal} -e ${editor}")'' "Open editor" { })
        (mkBind "SUPER + R" ''hl.dsp.exec_cmd("${terminal} -e lf")'' "Open file manager" { })
        (mkBind "SUPER + SHIFT + R" ''hl.dsp.exec_cmd("${terminal} -e btop")'' "Open system monitor" { })
        (mkBind "SUPER + S" ''hl.dsp.exec_cmd("${messenger}")'' "Open messenger" { })
        (mkBind "SUPER + V" ''hl.dsp.send_shortcut({ mods = "SHIFT", key = "Insert" })''
          "Paste (send Shift+Insert to focused window)"
          { }
        )
        (mkBind "SUPER + X" ''hl.dsp.send_shortcut({ mods = "CTRL", key = "X" })''
          "Send Ctrl+X to focused window"
          { }
        )
        (mkBind "SUPER + W" ''hl.dsp.exec_cmd("${browser} --new-window --ozone-platform=wayland")''
          "Open browser"
          { }
        )

        (mkBind "SUPER + SHIFT + SPACE" ''hl.dsp.exec_cmd("dms ipc call bar toggle index 0")'' "Toggle bar"
          { }
        )

        (mkBind "SUPER + Q" "hl.dsp.window.close()" "Close window" { })

        (mkBind "SUPER + ESCAPE" ''hl.dsp.exec_cmd("dms ipc call lock lock")'' "Lock screen" { })
        (mkBind "SUPER + SHIFT + ESCAPE" "hl.dsp.exit()" "Exit Hyprland" { })
        (mkBind "SUPER + CTRL + ESCAPE" ''hl.dsp.exec_cmd("reboot")'' "Reboot" { })
        (mkBind "SUPER + SHIFT + CTRL + ESCAPE" ''hl.dsp.exec_cmd("systemctl poweroff")'' "Power off" { })
        (mkBind "SUPER + SHIFT + SLASH" ''hl.dsp.exec_cmd("dms ipc call keybinds toggle hyprland")''
          "Show keybindings"
          { }
        )
        (mkBind "SUPER + I" ''hl.dsp.exec_cmd("dms ipc call inhibit toggle")'' "Toggle idle inhibit" { })

        (mkBind "SUPER + T" ''hl.dsp.layout("togglesplit")'' "Toggle split direction" { })
        # hl.config called outside config parsing applies immediately and
        # schedules the layout refresh.
        (mkBind "SUPER + A" ''
          function()
            hl.config({ general = { layout = "scrolling" } })
          end
        '' "Switch to scrolling layout" { })
        (mkBind "SUPER + SHIFT + A" ''
          function()
            hl.config({ general = { layout = "dwindle" } })
          end
        '' "Switch to dwindle layout" { })
        # colresize is a scrolling-layout message; no-op under dwindle.
        (mkBind "SUPER + CTRL + H" ''hl.dsp.layout("colresize all 0.333")'' "Set all columns to 1/3 width"
          { }
        )
        (mkBind "SUPER + CTRL + L" ''hl.dsp.layout("colresize all 0.5")'' "Set all columns to 1/2 width"
          { }
        )
        (mkBind "SUPER + BRACKETLEFT" ''hl.dsp.layout("consume_or_expel prev")''
          "Consume or expel window left"
          { }
        )
        (mkBind "SUPER + BRACKETRIGHT" ''hl.dsp.layout("consume_or_expel next")''
          "Consume or expel window right"
          { }
        )
        (mkBind "SUPER + APOSTROPHE" ''hl.dsp.layout("colresize +conf")'' "Cycle column width up" { })
        (mkBind "SUPER + SEMICOLON" ''hl.dsp.layout("colresize -conf")'' "Cycle column width down" { })
        (mkBind "SUPER + M" ''hl.dsp.layout("colresize 1.0")'' "Maximize column width" { })
        (mkBind "SUPER + P" "hl.dsp.window.pseudo()" "Toggle pseudotile" { })
        (mkBind "SUPER + SHIFT + F" "hl.dsp.window.float()" "Toggle floating" { })
        (mkBind "SUPER + F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'' "Toggle fullscreen" { })

        (mkBind "SUPER + LEFT" ''hl.dsp.focus({ direction = "l" })'' "Focus window left" { })
        (mkBind "SUPER + RIGHT" ''hl.dsp.focus({ direction = "r" })'' "Focus window right" { })
        (mkBind "SUPER + UP" ''hl.dsp.focus({ direction = "u" })'' "Focus window up" { })
        (mkBind "SUPER + DOWN" ''hl.dsp.focus({ direction = "d" })'' "Focus window down" { })

        (mkBind "SUPER + H" ''hl.dsp.focus({ direction = "l" })'' "Focus window left" { })
        (mkBind "SUPER + L" ''hl.dsp.focus({ direction = "r" })'' "Focus window right" { })
        (mkBind "SUPER + K" ''hl.dsp.focus({ direction = "u" })'' "Focus window up" { })
        (mkBind "SUPER + J" ''hl.dsp.focus({ direction = "d" })'' "Focus window down" { })

        (mkBind "SUPER + COMMA" ''hl.dsp.focus({ workspace = "-1" })'' "Previous workspace" { })
        (mkBind "SUPER + PERIOD" ''hl.dsp.focus({ workspace = "+1" })'' "Next workspace" { })
        # A closure, not a bare hl.plugin.gloview.toggle reference: the plugin
        # is nil during the first config pass.
        (mkBind "SUPER + O" "function() hl.plugin.gloview.toggle() end" "Workspace overview" { })

        # move rather than swap: under the scrolling layout a directional move
        # merges the window into an adjacent column, which a swap cannot do.
        (mkBind "SUPER + SHIFT + LEFT" ''hl.dsp.window.move({ direction = "l" })'' "Move window left" { })
        (mkBind "SUPER + SHIFT + RIGHT" ''hl.dsp.window.move({ direction = "r" })'' "Move window right" { })
        (mkBind "SUPER + SHIFT + UP" ''hl.dsp.window.move({ direction = "u" })'' "Move window up" { })
        (mkBind "SUPER + SHIFT + DOWN" ''hl.dsp.window.move({ direction = "d" })'' "Move window down" { })

        (mkBind "SUPER + SHIFT + H" ''hl.dsp.window.move({ direction = "l" })'' "Move window left" { })
        (mkBind "SUPER + SHIFT + L" ''hl.dsp.window.move({ direction = "r" })'' "Move window right" { })
        (mkBind "SUPER + SHIFT + K" ''hl.dsp.window.move({ direction = "u" })'' "Move window up" { })
        (mkBind "SUPER + SHIFT + J" ''hl.dsp.window.move({ direction = "d" })'' "Move window down" { })

        (mkBind "SUPER + MINUS" "hl.dsp.window.resize({ x = -100, y = 0, relative = true })"
          "Shrink window width"
          { }
        )
        (mkBind "SUPER + EQUAL" "hl.dsp.window.resize({ x = 100, y = 0, relative = true })"
          "Grow window width"
          { }
        )
        (mkBind "SUPER + SHIFT + MINUS" "hl.dsp.window.resize({ x = 0, y = -100, relative = true })"
          "Shrink window height"
          { }
        )
        (mkBind "SUPER + SHIFT + EQUAL" "hl.dsp.window.resize({ x = 0, y = 100, relative = true })"
          "Grow window height"
          { }
        )

        (mkBind "SUPER + mouse_down" ''hl.dsp.focus({ workspace = "e+1" })'' "Next open workspace" { })
        (mkBind "SUPER + mouse_up" ''hl.dsp.focus({ workspace = "e-1" })'' "Previous open workspace" { })

        (mkBind "SUPER + U" ''hl.dsp.workspace.toggle_special("magic")'' "Toggle special workspace" { })
        (mkBind "SUPER + SHIFT + U" ''hl.dsp.window.move({ workspace = "special:magic" })''
          "Move window to special workspace"
          { }
        )

        (mkBind "PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m region")'' "Screenshot region" { })
        (mkBind "SHIFT + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m window")'' "Screenshot window"
          { }
        )
        (mkBind "CTRL + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m output")'' "Screenshot output"
          { }
        )
        (mkBind "SUPER + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprpicker} -a")'' "Pick color" { })

        (mkBind "CTRL + SUPER + V" ''hl.dsp.exec_cmd("dms ipc call clipboard toggle")'' "Clipboard history"
          { }
        )

        (mkBind "SUPER + mouse:272" "hl.dsp.window.drag()" "Move window" { mouse = true; })
        (mkBind "SUPER + mouse:273" "hl.dsp.window.resize()" "Resize window" { mouse = true; })

        (mkBind "XF86AudioRaiseVolume" ''hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+")''
          "Volume up"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBind "XF86AudioLowerVolume" ''hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")''
          "Volume down"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBind "XF86AudioMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")'' "Mute" {
          locked = true;
          repeating = true;
        })
        (mkBind "XF86AudioMicMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")''
          "Mic mute"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBind "XF86MonBrightnessUp" ''hl.dsp.exec_cmd("${getExe pkgs.brightnessctl} set 655+")''
          "Brightness up"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBind "XF86MonBrightnessDown" ''hl.dsp.exec_cmd("${getExe pkgs.brightnessctl} set 655-")''
          "Brightness down"
          {
            locked = true;
            repeating = true;
          }
        )

        (mkBind "XF86AudioNext" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} next")'' "Next track" {
          locked = true;
        })
        (mkBind "XF86AudioPause" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} play-pause")'' "Play/pause" {
          locked = true;
        })
        (mkBind "XF86AudioPlay" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} play-pause")'' "Play/pause" {
          locked = true;
        })
        (mkBind "XF86AudioPrev" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} previous")'' "Previous track" {
          locked = true;
        })
      ]
      ++ (concatMap (
        i:
        let
          n = toString i;
        in
        [
          (mkBind "SUPER + ${n}" "hl.dsp.focus({ workspace = ${n} })" "Switch to workspace ${n}" { })
          (mkBind "SUPER + SHIFT + ${n}" "hl.dsp.window.move({ workspace = ${n} })"
            "Move window to workspace ${n}"
            { }
          )
        ]
      ) (range 1 9))
      ++ [
        (mkBind "SUPER + 0" "hl.dsp.focus({ workspace = 10 })" "Switch to workspace 10" { })
        (mkBind "SUPER + SHIFT + 0" "hl.dsp.window.move({ workspace = 10 })" "Move window to workspace 10"
          { }
        )
      ];
    };
}
