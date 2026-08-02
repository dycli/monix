# The Hyprland desktop concern: compositor + session at the system level, the
# user's full Hyprland configuration at the home level. Hyprland comes from
# nixpkgs; the gloview input is plugin source only.
{ inputs, ... }:
{
  flake.nixosModules.hyprland =
    { lib, pkgs, ... }:
    {
      programs.hyprland.enable = true;

      # UWSM owns the systemd session lifecycle. In this nixpkgs pin
      # withUWSM only flips programs.uwsm.enable; it neither registers
      # Hyprland with UWSM nor adds a session entry.
      programs.hyprland.withUWSM = true;

      # nixpkgs' waylandCompositors entry cannot pass -D before --, so
      # uwsm seeds XDG_CURRENT_DESKTOP from the binary name and its quirk
      # plugin appends rather than replaces, yielding
      # "start-hyprland:Hyprland". Hyprland matches that exactly against
      # "Hyprland" and otherwise warns about external management every
      # session. Writing the session entry here passes -D Hyprland up
      # front; mkForce replaces the plain entry rather than adding to it,
      # so the greeter offers one Hyprland session.
      services.displayManager.sessionPackages = lib.mkForce [
        (pkgs.writeTextFile {
          name = "hyprland-uwsm";
          text = ''
            [Desktop Entry]
            Name=Hyprland
            Comment=Hyprland compositor managed by UWSM
            Exec=${lib.getExe pkgs.uwsm} start -F -D Hyprland -- ${lib.getExe' pkgs.hyprland "start-hyprland"}
            Type=Application
          '';
          # Must launch start-hyprland rather than the raw binary: the
          # "started without start-hyprland" warning clears only with a
          # valid --watchdog-fd, a pipe start-hyprland creates when it
          # forks. It does no systemd manipulation itself, so nesting it
          # inside the uwsm-managed unit is safe.
          destination = "/share/wayland-sessions/hyprland-uwsm.desktop";
          derivationArgs = {
            # Mirrors nixpkgs' mk_uwsm_desktop_entry passthru so
            # sessionPackages can find the session id.
            passthru.providedSessions = [ "hyprland-uwsm" ];
          };
        })
      ];

      hardware.graphics.enable = true;

      xdg.portal.enable = true;
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

      # Without flatpak installed its document portal fails at session
      # start and degrades the user service manager; the hyprland and gtk
      # portals do not depend on it.
      systemd.user.units."xdg-document-portal.service".enable = false;

      # greetd and the session launch command are configured by the
      # greeter module in dank.mod.nix.

      # Secret storage for desktop applications, unlocked at greetd login.
      services.gnome.gnome-keyring.enable = true;
      security.pam.services.greetd.enableGnomeKeyring = true;
    };

  # configType is pinned to "lua" because home-manager otherwise infers it
  # from home.stateVersion, so a future bump could silently switch config
  # generation.
  #
  # Every bind carries a description: the keybinds overlay reads them back
  # via `hyprctl binds -j`, since Lua is executed rather than parsed.
  flake.homeModules.hyprland =
    {
      config,
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.generators) mkLuaInline;
      inherit (lib.lists) concatMap range;
      inherit (lib.attrsets) recursiveUpdate;
      inherit (lib.meta) getExe getExe';

      # One hl.bind call per element; opts merges over the description, so
      # callers add only the flags that differ.
      mkBind = keys: dispatcherLua: description: opts: {
        _args = [
          keys
          (mkLuaInline dispatcherLua)
          (recursiveUpdate { inherit description; } opts)
        ];
      };

      # One `hl.env(key, value)` call per list element.
      mkEnv = key: value: {
        _args = [
          key
          value
        ];
      };

      # The session's default applications come from the desktopApps
      # options (default-apps.mod.nix).
      terminal = getExe config.desktopApps.terminal;
      browser = getExe config.desktopApps.browser;
      messenger = getExe config.desktopApps.messenger;
      passwordManager = getExe config.desktopApps.passwordManager;
      email = getExe config.desktopApps.email;
      inherit (config.desktopApps) editor;
    in
    {
      # DMS writes the monitor layout here at runtime, so it must be a
      # real user-writable file rather than a store symlink; `f` seeds it
      # without touching an existing one.
      systemd.user.tmpfiles.rules = [
        "f %h/.config/hypr/dms/outputs.lua 0644 - - -"
        # Cursor theme and size are DMS-owned the same way.
        "f %h/.config/hypr/dms/cursor.lua 0644 - - -"
      ];

      wayland.windowManager.hyprland = {
        enable = true;
        configType = "lua";

        # The NixOS-level programs.hyprland.enable installs these
        # system-wide; null avoids a second home-manager copy.
        package = null;
        portalPackage = null;

        # gloview (Mission Control-style overview, on the TAB bind below),
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
        ];

        # UWSM brings up the graphical-session targets itself, so this
        # module's own hook would race it; `uwsm finalize` in the first
        # autostart line exports the session environment instead.
        systemd.enable = false;

        # pcall rather than a bare require: if the seed file is missing,
        # a first login racing tmpfiles would otherwise abort the whole
        # Lua config and take the session down.
        extraConfig = ''
          pcall(require, "dms.outputs")
          pcall(require, "dms.cursor")
        '';

        settings = {
          env = [
            (mkEnv "GDK_SCALE" "2")
            # Cursor env comes from DMS's cursor.lua, not static config.
            (mkEnv "GDK_BACKEND" "wayland")
            (mkEnv "QT_QPA_PLATFORM" "wayland")
            # qt6ct-kde so DMS's Qt colours reach Qt apps; the widget
            # style itself is picked in qt6ct.
            (mkEnv "QT_QPA_PLATFORMTHEME" "qt6ct")
            (mkEnv "SDL_VIDEODRIVER" "wayland")
            (mkEnv "MOZ_ENABLE_WAYLAND" "1")
            (mkEnv "ELECTRON_OZONE_PLATFORM_HINT" "wayland")
            (mkEnv "OZONE_PLATFORM" "wayland")
            # Expanded statically: Hyprland's env does no shell expansion,
            # so a literal $VAR would propagate into the session and break
            # nvim's runtimepath expansion under non-POSIX shells.
            (mkEnv "XDG_DATA_DIRS" "/etc/profiles/per-user/${osConfig.primaryUser}/share:/run/current-system/sw/share")
            (mkEnv "EDITOR" editor)
            # The theme DMS's generated gtk.css is written against.
            (mkEnv "GTK_THEME" "adw-gtk3-dark")
          ];

          config = {
            general = {
              gaps_in = 0;
              gaps_out = 0;
              border_size = 2;

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

            # Roughly half the plugin's stock timings; snappy but still
            # spatial. Selection nav on vim keys plus the arrows — the
            # key lists replace the defaults, so both are named.
            plugin.gloview = {
              duration = 120;
              switch_duration = 100;
              move_duration = 100;

              key_left = "h left";
              key_right = "l right";
              key_up = "k up";
              key_down = "j down";

              # O everywhere TAB was: the toggle bind below is SUPER+O and
              # falls through to close, so these move off the tab defaults
              # to match.
              key_next_workspace = "o";
              key_prev_workspace = "shift+o";
            };

            input = {
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
            {
              fingers = 3;
              direction = "up";
              action = mkLuaInline "hl.plugin.gloview.open";
            }
            {
              fingers = 3;
              direction = "down";
              action = mkLuaInline "hl.plugin.gloview.close";
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

          # `uwsm finalize` must run first: it exports the session
          # variables and signals wayland-wm@Hyprland ready, unblocking
          # graphical-session.target. Long-running autostarts are wrapped
          # in `uwsm app --` to get their own scopes; one-shot keybind
          # execs are not.
          on = {
            _args = [
              "hyprland.start"
              (mkLuaInline ''
                function()
                  hl.exec_cmd("${getExe pkgs.uwsm} finalize XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_ID")
                  hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe pkgs.wl-clip-persist} --clipboard regular")
                  hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe' pkgs.wl-clipboard "wl-paste"} --watch ${getExe pkgs.cliphist} store")
                end
              '')
            ];
          };

          bind = [
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
            # SHIFT+SLASH is "?", the conventional help key; K belongs to
            # the vim focus cluster below.
            (mkBind "SUPER + SHIFT + SLASH" ''hl.dsp.exec_cmd("dms ipc call keybinds toggle hyprland")''
              "Show keybindings"
              { }
            )
            (mkBind "SUPER + I" ''hl.dsp.exec_cmd("dms ipc call inhibit toggle")'' "Toggle idle inhibit" { })

            (mkBind "SUPER + T" ''hl.dsp.layout("togglesplit")'' "Toggle split direction" { })
            # Live layout switch via hl.config: outside config parsing it
            # applies immediately and schedules the layout refresh. The
            # scrolling column behaviour (50:50 columns, a lone window
            # spanning the screen) is the pinned defaults — column_width
            # 0.5, fullscreen_on_one_column true — so no scrolling block.
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
            (mkBind "SUPER + CTRL + H" ''hl.dsp.layout("colresize all 0.333")''
              "Set all columns to 1/3 width"
              { }
            )
            (mkBind "SUPER + CTRL + L" ''hl.dsp.layout("colresize all 0.5")''
              "Set all columns to 1/2 width"
              { }
            )
            # The niri column vocabulary: a lone window merges into the
            # adjacent column, a stacked one pops out toward that side.
            (mkBind "SUPER + BRACKETLEFT" ''hl.dsp.layout("consume_or_expel prev")''
              "Consume or expel window left"
              { }
            )
            (mkBind "SUPER + BRACKETRIGHT" ''hl.dsp.layout("consume_or_expel next")''
              "Consume or expel window right"
              { }
            )
            (mkBind "SUPER + APOSTROPHE" ''hl.dsp.layout("colresize +conf")''
              "Cycle column width up"
              { }
            )
            (mkBind "SUPER + SEMICOLON" ''hl.dsp.layout("colresize -conf")''
              "Cycle column width down"
              { }
            )
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
            # The plugin registers hl.plugin.gloview.*; the bind takes the
            # function reference, not a call.
            (mkBind "SUPER + O" "hl.plugin.gloview.toggle" "Workspace overview" { })

            # move rather than swap: under the scrolling layout a directional
            # move merges the window into an adjacent column (the vertical
            # stack), which swap — a pure in-place exchange — can never do.
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

            # S is taken by the messenger bind.
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
      };
    };
}
