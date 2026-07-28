# The Hyprland desktop concern: compositor + session at the system level, the
# user's full Hyprland configuration at the home level. Hyprland comes from
# nixpkgs; there are no Hyprland-specific flake inputs.
{
  flake.nixosModules.hyprland =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf config.isDesktop {
        programs.hyprland.enable = true;

        # UWSM owns the systemd session lifecycle; the home-manager Hyprland
        # module's own hook is disabled (see homeModules.hyprland below). In
        # this nixpkgs pin, `withUWSM` alone only flips `programs.uwsm.enable`
        # — it does not register Hyprland with UWSM or add a session entry.
        programs.hyprland.withUWSM = true;

        # nixpkgs' `waylandCompositors` desktop entry (via `uwsm start -F --
        # start-hyprland`) gives no way to pass `-D`/`--desktop-names` before
        # `--`, so uwsm seeds XDG_CURRENT_DESKTOP from the binary name
        # ("start-hyprland") and its quirk plugin appends ":Hyprland" instead
        # of replacing it, producing "start-hyprland:Hyprland". Hyprland's
        # startup check does an exact-string match against "Hyprland", so
        # that trips the "managed externally" notification every session.
        # Bypassed here by writing the wayland-sessions entry directly with
        # `-D Hyprland` passed to `uwsm start`, seeding XDG_CURRENT_DESKTOP
        # correctly up front. mkForce below replaces (not supplements) the
        # plain non-UWSM entry `programs.hyprland.enable` installs, so the
        # greeter offers exactly one Hyprland session.
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
            # Must launch start-hyprland, not the raw binary: Hyprland's
            # "started without start-hyprland" warning only clears with a
            # valid --watchdog-fd, a pipe only start-hyprland creates when it
            # forks+execs Hyprland — no env var can substitute. start-hyprland
            # itself does no systemd/target manipulation (just a crash-restart
            # watchdog), so nesting it in the uwsm-managed unit is safe.
            destination = "/share/wayland-sessions/hyprland-uwsm.desktop";
            derivationArgs = {
              # Mirrors nixpkgs' own `mk_uwsm_desktop_entry` passthru so
              # `services.displayManager.sessionPackages` can find the
              # session id this package provides.
              passthru.providedSessions = [ "hyprland-uwsm" ];
            };
          })
        ];

        hardware.graphics.enable = true;

        xdg.portal.enable = true;
        xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

        # The flatpak document portal fails at session start (fusermount3 not
        # on PATH) since flatpak isn't installed, degrading the user service
        # manager. Mask it; hyprland/gtk portals don't depend on it.
        systemd.user.units."xdg-document-portal.service".enable = false;

        # greetd itself, and the session launch command (start-hyprland when
        # present, see the dms-greeter asset script), are configured by the
        # DankMaterialShell greeter module (see dank.mod.nix).

        # Secret storage for desktop applications, unlocked at greetd login.
        services.gnome.gnome-keyring.enable = true;
        security.pam.services.greetd.enableGnomeKeyring = true;
      };
    };

  # configType is pinned explicitly to "lua" (Hyprland deprecated hyprlang;
  # home-manager infers it from home.stateVersion otherwise) so an unrelated
  # future stateVersion bump can't silently switch config generation.
  #
  # Every bind carries a `description`: the DMS keybinds overlay (SUPER+K)
  # reads these back via `hyprctl binds -j` at runtime, since Lua is
  # executed, not parsed. Keep descriptions and behavior in sync.
  flake.homeModules.hyprland =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.generators) mkLuaInline;
      inherit (lib.lists) concatMap range;
      inherit (lib.attrsets) recursiveUpdate;
      inherit (lib.meta) getExe getExe';

      # One `hl.bind(keys, dispatcher, opts)` call per list element.
      # `opts` merges over `{ description = ...; }`, so callers only need to
      # add flags (`locked`, `repeating`, `mouse`) that differ from none.
      mkBind =
        keys: dispatcherLua: description: opts:
        {
          _args = [
            keys
            (mkLuaInline dispatcherLua)
            (recursiveUpdate { inherit description; } opts)
          ];
        };

      # One `hl.env(key, value)` call per list element.
      mkEnv = key: value: { _args = [ key value ]; };
    in
    {
      config = mkIf osConfig.isDesktop {
        # DMS writes the monitor layout it manages (Settings → Displays) to
        # ~/.config/hypr/dms/outputs.lua at runtime, so it must be a real
        # user-writable file, not a home.file store symlink — seeded empty by
        # a tmpfiles rule (`f` never touches an existing file).
        systemd.user.tmpfiles.rules = [
          "f %h/.config/hypr/dms/outputs.lua 0644 - - -"
          # Cursor theme/size are DMS-owned the same way (Settings → cursor);
          # the theme package itself is installed by cursor.mod.nix.
          "f %h/.config/hypr/dms/cursor.lua 0644 - - -"
        ];

        wayland.windowManager.hyprland = {
          enable = true;
          configType = "lua";

          # Deferred to the NixOS-level `programs.hyprland.enable`, which
          # installs the compositor and portal system-wide; null avoids a
          # second HM-managed copy of each package.
          package = null;
          portalPackage = null;

          # UWSM owns the systemd session via the custom display-manager
          # entry (nixosModules.hyprland above), running `uwsm start -F -D
          # Hyprland -- start-hyprland` which brings up the graphical-session
          # targets itself; this module's own hook would race it. Session env
          # export is done instead by `uwsm finalize` in the first autostart
          # line below.
          systemd.enable = false;

          # DMS-owned monitor config (see the tmpfiles rule above). pcall, not
          # a bare require: if the seed file is missing (first login racing
          # tmpfiles), a bare require would abort the whole Lua config and
          # take the session down with it.
          extraConfig = ''
            pcall(require, "dms.outputs")
            pcall(require, "dms.cursor")
          '';

          settings = {
            env = [
              (mkEnv "GDK_SCALE" "2")
              # Cursor theme/size env comes from DMS's dms/cursor.lua (see
              # the tmpfiles rule above), not static config.
              (mkEnv "GDK_BACKEND" "wayland")
              (mkEnv "QT_QPA_PLATFORM" "wayland")
              # qt6ct(-kde) so DMS's "Apply Qt Themes" colors reach Qt apps
              # (see dank.mod.nix). Widget style itself is picked in qt6ct.
              (mkEnv "QT_QPA_PLATFORMTHEME" "qt6ct")
              (mkEnv "SDL_VIDEODRIVER" "wayland")
              (mkEnv "MOZ_ENABLE_WAYLAND" "1")
              (mkEnv "ELECTRON_OZONE_PLATFORM_HINT" "wayland")
              (mkEnv "OZONE_PLATFORM" "wayland")
              # Statically expanded: Hyprland's `env` does no shell expansion,
              # so a literal `$VAR` would propagate into the session and break
              # nvim's runtimepath expansion (E79) under non-POSIX shells.
              (mkEnv "XDG_DATA_DIRS"
                "/etc/profiles/per-user/${osConfig.primaryUser}/share:/run/current-system/sw/share"
              )
              (mkEnv "EDITOR" "nvim")
              # adw-gtk3: the theme DMS's generated gtk.css is written against.
              (mkEnv "GTK_THEME" "adw-gtk3-dark")
            ];

            # CORE CONFIG — one `hl.config({...})` call covering every category.
            config = {
              general = {
                gaps_in = 0;
                gaps_out = 0;
                border_size = 2;

                resize_on_border = false;
                allow_tearing = false;
                layout = "dwindle";
              };

              decoration = {
                rounding = 2;

                shadow.enabled = false;

                blur = {
                  enabled = true;
                  size = 3;
                  passes = 1;
                  vibrancy = 0.1696;
                };
              };

              animations.enabled = false;

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

            # GESTURES — one `hl.gesture({...})` call per list element.
            gesture = [
              {
                fingers = 3;
                direction = "horizontal";
                action = "workspace";
              }
              {
                fingers = 4;
                direction = "swipe";
                action = "resize";
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

            # WINDOW RULES — one `hl.window_rule({...})` call per element.
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
                # Fix some dragging issues with XWayland.
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

            # LAYER RULES.
            layer_rule = [
              {
                match.namespace = "^(dms)$";
                no_anim = true;
              }
            ];

            # AUTOSTART — runs once at compositor startup. dms and ghostty
            # start via their own units' WantedBy = graphical-session.target
            # (see ghostty.mod.nix, dank.mod.nix), brought up by UWSM.
            # `uwsm finalize` must run first: it exports session vars and
            # signals `wayland-wm@Hyprland.service` ready, unblocking
            # graphical-session.target. Long-running autostarts are wrapped in
            # `uwsm app --` so they run as their own systemd scopes; keybind
            # execs stay unwrapped since they're one-shot, not long-lived.
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

            # BINDINGS
            bind =
              [
                (mkBind "SUPER + RETURN" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty}")'' "Open terminal" { })
                (mkBind "SUPER + BACKSPACE" ''hl.dsp.exec_cmd("dms ipc call powermenu toggle")'' "Power menu" { })
                (mkBind "SUPER + SLASH" ''hl.dsp.exec_cmd("${getExe pkgs.keepassxc}")'' "Open password manager" { })
                (mkBind "SUPER + C" ''hl.dsp.send_shortcut({ mods = "CTRL", key = "Insert" })''
                  "Copy (send Ctrl+Insert to focused window)"
                  { }
                )
                (mkBind "SUPER + D" ''hl.dsp.exec_cmd("dms ipc call spotlight toggle")''
                  "App launcher"
                  { }
                )
                (mkBind "SUPER + N" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty} -e nvim")'' "Open editor" { })
                (mkBind "SUPER + R" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty} -e lf")''
                  "Open file manager"
                  { }
                )
                (mkBind "SUPER + SHIFT + R" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty} -e btop")''
                  "Open system monitor"
                  { }
                )
                (mkBind "SUPER + S" ''hl.dsp.exec_cmd("signal-desktop")'' "Open messenger" { })
                (mkBind "SUPER + V" ''hl.dsp.send_shortcut({ mods = "SHIFT", key = "Insert" })''
                  "Paste (send Shift+Insert to focused window)"
                  { }
                )
                (mkBind "SUPER + X" ''hl.dsp.send_shortcut({ mods = "CTRL", key = "X" })''
                  "Send Ctrl+X to focused window"
                  { }
                )
                (mkBind "SUPER + W"
                  ''hl.dsp.exec_cmd("${getExe pkgs.brave} --new-window --ozone-platform=wayland")''
                  "Open browser"
                  { }
                )

                (mkBind "SUPER + SHIFT + SPACE" ''hl.dsp.exec_cmd("dms ipc call bar toggle index 0")''
                  "Toggle bar"
                  { }
                )

                (mkBind "SUPER + Q" ''hl.dsp.window.close()'' "Close window" { })

                (mkBind "SUPER + ESCAPE" ''hl.dsp.exec_cmd("dms ipc call lock lock")'' "Lock screen" { })
                (mkBind "SUPER + SHIFT + ESCAPE" ''hl.dsp.exit()'' "Exit Hyprland" { })
                (mkBind "SUPER + CTRL + ESCAPE" ''hl.dsp.exec_cmd("reboot")'' "Reboot" { })
                (mkBind "SUPER + SHIFT + CTRL + ESCAPE" ''hl.dsp.exec_cmd("systemctl poweroff")'' "Power off" { })
                (mkBind "SUPER + K" ''hl.dsp.exec_cmd("dms ipc call keybinds toggle hyprland")''
                  "Show keybindings"
                  { }
                )
                (mkBind "SUPER + I" ''hl.dsp.exec_cmd("dms ipc call inhibit toggle")'' "Toggle idle inhibit" { })

                (mkBind "SUPER + J" ''hl.dsp.layout("togglesplit")'' "Toggle split direction" { })
                (mkBind "SUPER + P" ''hl.dsp.window.pseudo()'' "Toggle pseudotile" { })
                (mkBind "SUPER + SHIFT + F" ''hl.dsp.window.float()'' "Toggle floating" { })
                (mkBind "SUPER + F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'' "Toggle fullscreen" { })

                (mkBind "SUPER + LEFT" ''hl.dsp.focus({ direction = "l" })'' "Focus window left" { })
                (mkBind "SUPER + RIGHT" ''hl.dsp.focus({ direction = "r" })'' "Focus window right" { })
                (mkBind "SUPER + UP" ''hl.dsp.focus({ direction = "u" })'' "Focus window up" { })
                (mkBind "SUPER + DOWN" ''hl.dsp.focus({ direction = "d" })'' "Focus window down" { })

                (mkBind "SUPER + COMMA" ''hl.dsp.focus({ workspace = "-1" })'' "Previous workspace" { })
                (mkBind "SUPER + PERIOD" ''hl.dsp.focus({ workspace = "+1" })'' "Next workspace" { })

                (mkBind "SUPER + SHIFT + LEFT" ''hl.dsp.window.swap({ direction = "l" })'' "Swap window left" { })
                (mkBind "SUPER + SHIFT + RIGHT" ''hl.dsp.window.swap({ direction = "r" })'' "Swap window right" { })
                (mkBind "SUPER + SHIFT + UP" ''hl.dsp.window.swap({ direction = "u" })'' "Swap window up" { })
                (mkBind "SUPER + SHIFT + DOWN" ''hl.dsp.window.swap({ direction = "d" })'' "Swap window down" { })

                (mkBind "SUPER + MINUS" ''hl.dsp.window.resize({ x = -100, y = 0, relative = true })''
                  "Shrink window width"
                  { }
                )
                (mkBind "SUPER + EQUAL" ''hl.dsp.window.resize({ x = 100, y = 0, relative = true })''
                  "Grow window width"
                  { }
                )
                (mkBind "SUPER + SHIFT + MINUS" ''hl.dsp.window.resize({ x = 0, y = -100, relative = true })''
                  "Shrink window height"
                  { }
                )
                (mkBind "SUPER + SHIFT + EQUAL" ''hl.dsp.window.resize({ x = 0, y = 100, relative = true })''
                  "Grow window height"
                  { }
                )

                (mkBind "SUPER + mouse_down" ''hl.dsp.focus({ workspace = "e+1" })'' "Next open workspace" { })
                (mkBind "SUPER + mouse_up" ''hl.dsp.focus({ workspace = "e-1" })'' "Previous open workspace" { })

                # SUPER+U, not SUPER+S: S is taken by the messenger bind.
                (mkBind "SUPER + U" ''hl.dsp.workspace.toggle_special("magic")'' "Toggle special workspace" { })
                (mkBind "SUPER + SHIFT + U" ''hl.dsp.window.move({ workspace = "special:magic" })''
                  "Move window to special workspace"
                  { }
                )

                (mkBind "PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m region")''
                  "Screenshot region"
                  { }
                )
                (mkBind "SHIFT + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m window")''
                  "Screenshot window"
                  { }
                )
                (mkBind "CTRL + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m output")''
                  "Screenshot output"
                  { }
                )
                (mkBind "SUPER + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprpicker} -a")'' "Pick color" { })

                (mkBind "CTRL + SUPER + V" ''hl.dsp.exec_cmd("dms ipc call clipboard toggle")''
                  "Clipboard history"
                  { }
                )

                (mkBind "SUPER + mouse:272" ''hl.dsp.window.drag()'' "Move window" { mouse = true; })
                (mkBind "SUPER + mouse:273" ''hl.dsp.window.resize()'' "Resize window" { mouse = true; })

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
                (mkBind "XF86AudioMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")''
                  "Mute"
                  {
                    locked = true;
                    repeating = true;
                  }
                )
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

                (mkBind "XF86AudioNext" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} next")''
                  "Next track"
                  { locked = true; }
                )
                (mkBind "XF86AudioPause" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} play-pause")''
                  "Play/pause"
                  { locked = true; }
                )
                (mkBind "XF86AudioPlay" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} play-pause")''
                  "Play/pause"
                  { locked = true; }
                )
                (mkBind "XF86AudioPrev" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} previous")''
                  "Previous track"
                  { locked = true; }
                )
              ]
              # Switch to / move to workspaces 1-9.
              ++ (
                concatMap
                  (
                    i:
                    let
                      n = toString i;
                    in
                    [
                      (mkBind "SUPER + ${n}" ''hl.dsp.focus({ workspace = ${n} })'' "Switch to workspace ${n}" { })
                      (mkBind "SUPER + SHIFT + ${n}" ''hl.dsp.window.move({ workspace = ${n} })''
                        "Move window to workspace ${n}"
                        { }
                      )
                    ]
                  )
                  (range 1 9)
              )
              ++ [
                (mkBind "SUPER + 0" ''hl.dsp.focus({ workspace = 10 })'' "Switch to workspace 10" { })
                (mkBind "SUPER + SHIFT + 0" ''hl.dsp.window.move({ workspace = 10 })''
                  "Move window to workspace 10"
                  { }
                )
              ];
          };
        };
      };
    };
}
