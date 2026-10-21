# Each assistant's own browser on the host: a visible Brave on a screen of
# its own, drawn by the GPU, so sites see a real desktop browser on the
# home connection rather than a headless or software-rendered one (the
# WebGL renderer is the tell a VM cannot hide). cage runs on a headless
# wlroots output rendered on the GPU's render node, with Playwright MCP as
# its one app; the server opens Brave when a client connects and closes it
# when the last one leaves. wayvnc shows the same screen so the person can
# take over (captcha, two-factor) at <name>-screen.<domain>.
#
# Each browser runs as an account of its own, not the assistant's: it sees
# its profile and its desk and nothing of the assistant, the household or
# another browser. Its network is the internet only, plus its own loopback
# address, where the MCP server and VNC listen; the assistant is admitted
# to that address alone. The desk is shared with the assistant through the
# browser's group: screenshots and downloads out, uploads in.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.assistant-browser;
  flake.nixosModules.assistant-browser =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets)
        attrNames
        listToAttrs
        mapAttrs'
        nameValuePair
        ;
      inherit (lib.lists) concatMap singleton;
      inherit (lib.meta) getExe getExe';
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatStringsSep;
      inherit (lib) types;
      inherit (lib.ship) browsers fences;

      cfg = config.ship.browsers;
      owners = attrNames cfg;

      user = n: "${n}-browser";
      home = n: "/var/lib/browsers/${n}";
      desk = n: "${home n}/desk";
      addr = n: browsers.addr cfg.${n}.index;
      runtime = n: "/run/${user n}";
      session = n: {
        XDG_RUNTIME_DIR = runtime n;
        WAYLAND_DISPLAY = "wayland-0";
      };

      inherit (import ./novnc.nix pkgs) novnc websockify;
      playwright = import ./playwright-mcp.nix pkgs;

      desktop =
        n:
        let
          # The headless output starts at wlroots' 1280x720, so it is sized
          # to the screen before the browser opens. XWayland's DISPLAY goes
          # so Brave draws on Wayland directly.
          browse = pkgs.writeShellScript "${user n}-browse" ''
            ${getExe pkgs.wlr-randr} --output HEADLESS-1 --custom-mode ${browsers.screen}
            unset DISPLAY
            exec ${getExe playwright} "$@"
          '';
        in
        pkgs.writeShellApplication {
          name = "${user n}-desktop";
          runtimeInputs = [
            pkgs.cage
            pkgs.coreutils
          ];
          text = ''
            install -d -m 0700 ${home n}/profile
            export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
            export WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=${browsers.renderNode}
            export NIXOS_OZONE_WL=1
            # The profile goes by environment: the nixpkgs wrapper turns
            # on isolated mode, which refuses a profile, unless this is set.
            export PLAYWRIGHT_MCP_USER_DATA_DIR=${home n}/profile
            exec cage -- ${browse} \
              --host ${addr n} --port ${toString browsers.mcpPort} \
              --allowed-hosts ${addr n},${addr n}:${toString browsers.mcpPort} \
              --browser chrome --executable-path ${getExe pkgs.brave} --sandbox \
              --shared-browser-context \
              --output-dir ${desk n}
          '';
        };

      # The browser's own fence: the internet, resolved's stub and its own
      # loopback address, nothing private. Shared by the browser and VNC.
      fence = n: {
        IPAddressAllow = [
          "${addr n}/32"
          "127.0.0.53/32"
        ];
        IPAddressDeny = fences.internetOnlyDeny ++ [
          "127.0.0.0/8"
          "::1/128"
        ];
      };

      confined = n: {
        User = user n;
        Group = user n;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = singleton (home n);
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        LockPersonality = true;
      };
    in
    {
      options.ship.browsers = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              index = mkOption {
                type = types.ints.between 1 99;
                description = "Fixes the browser's loopback address and screen port.";
              };
              users = mkOption {
                type = types.listOf types.str;
                description = "Accounts that drive this browser and share its desk.";
              };
            };
          }
        );
        default = { };
        description = "Assistants with a browser of their own on this host.";
      };

      config = {
        users.users = listToAttrs (
          map (
            n:
            nameValuePair (user n) {
              isSystemUser = true;
              group = user n;
              home = home n;
              # The GPU's render node, for the compositor and Brave.
              extraGroups = singleton "render";
            }
          ) owners
          ++ concatMap (
            n:
            map (u: nameValuePair u { extraGroups = singleton (user n); }) cfg.${n}.users
          ) owners
        );
        users.groups = listToAttrs (map (n: nameValuePair (user n) { }) owners);

        # The profile is the browser's alone; the desk is setgid so what
        # either side writes stays the group's.
        systemd.tmpfiles.rules =
          singleton "d /var/lib/browsers 0755 root root -"
          ++ concatMap (n: [
            "d ${home n} 0750 ${user n} ${user n} -"
            "d ${home n}/profile 0700 ${user n} ${user n} -"
            "d ${desk n} 2770 ${user n} ${user n} -"
          ]) owners;

        shipProxy.routes = mapAttrs' (
          n: b: nameValuePair "${n}-screen" { port = browsers.screenPort b.index; }
        ) cfg;

        systemd.services = listToAttrs (
          concatMap (n: [
            (nameValuePair (user n) {
              description = "${n}'s browser: Brave under cage on the GPU, driven by Playwright MCP";
              wantedBy = singleton "multi-user.target";
              after = singleton "network.target";
              environment = session n;
              serviceConfig = confined n // fence n // {
                RuntimeDirectory = user n;
                RuntimeDirectoryMode = "0700";
                ExecStart = getExe (desktop n);
                Restart = "always";
                RestartSec = 3;
                # A runaway tab ends this browser, not the host's services.
                MemoryHigh = "4G";
                MemoryMax = "6G";
                TasksMax = 2048;
              };
            })
            (nameValuePair "${user n}-vnc" {
              description = "${n}'s browser screen over VNC, for the person to take over";
              wantedBy = singleton "multi-user.target";
              bindsTo = singleton "${user n}.service";
              after = singleton "${user n}.service";
              environment = session n;
              serviceConfig = confined n // fence n // {
                # cage offers only wlr-screencopy, over which wayvnc sends
                # no cursor image; -r paints the pointer into the frame.
                ExecStart = "${getExe pkgs.wayvnc} -r ${addr n} ${toString browsers.vncPort}";
                # The compositor's socket appears a moment after it starts;
                # a start that fails meanwhile reads as a failed deploy.
                ExecStartPre = "${pkgs.bash}/bin/bash -c 'until [ -S ${runtime n}/wayland-0 ]; do sleep 0.2; done'";
                TimeoutStartSec = 30;
                Restart = "always";
                RestartSec = 2;
              };
            })
            (nameValuePair "${n}-screen" {
              description = "${n}'s browser screen over the tailnet";
              wantedBy = singleton "multi-user.target";
              after = singleton "network.target";
              serviceConfig = lib.ship.hardened.vendor // {
                DynamicUser = true;
                ExecStart = concatStringsSep " " [
                  (getExe' websockify "websockify")
                  "--web ${novnc}/share/webapps/novnc"
                  "127.0.0.1:${toString (browsers.screenPort cfg.${n}.index)}"
                  "${addr n}:${toString browsers.vncPort}"
                ];
                Restart = "always";
                RestartSec = 5;
                IPAddressAllow = [
                  "127.0.0.1"
                  (addr n)
                ];
                IPAddressDeny = "any";
              };
            })
          ]) owners
        );
      };
    };
}
