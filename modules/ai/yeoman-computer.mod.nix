# Each assistant's own computer: a persistent microVM with a desktop that
# only it touches. Brave runs full screen under cage on a headless
# wlroots output, driven by Playwright MCP over HTTP on the guest's
# address, and wayvnc shows the same screen so the person can take over
# (captcha, two-factor) from a viewer on the host. The MCP server shares
# one browser between its clients and closes it when the last one leaves;
# the assistant connects once per reply, so a keeper in the guest holds a
# session of its own while the assistant has a lease on the browser: half
# an hour past each use, or until told to let go. The browser profile
# lives on a volume that survives reboots and rebuilds, so site logins
# stay; `<name>-computer-reset` wipes it back to a clean desk. A folder
# shared over virtiofs is the desk: screenshots and downloads land there
# for the assistant on the host to read, and files the assistant leaves
# there the browser can upload. The screen is a page on the tailnet,
# <name>-screen.<domain>: noVNC through websockify to the guest's VNC;
# the assistant gives the person the link when they must take over.
#
# Nothing of the household is in the guest: no tailnet, no store share,
# no secret, no login but the ones the assistant makes on sites. Its
# network is the internet only (yeoman-network.mod.nix).
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.yeoman-computer;
  flake.nixosModules.yeoman-computer =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) attrNames listToAttrs nameValuePair;
      inherit (lib.lists) concatLists singleton;
      inherit (lib.meta) getExe getExe';
      inherit (lib.options) mkOption;
      inherit (lib.strings) fixedWidthString;
      inherit (lib) readFile types;
      inherit (lib.ship) computers;

      indexed = computers.indexes config.yeoman.instances;
      owners = attrNames indexed;
      addr = n: computers.addr indexed.${n};

      vm = n: "${n}-pc";
      desk = n: "${computers.desks}/${n}";
      screenPort = n: computers.screenPort indexed.${n};
      screen = n: "${n}-screen";
      screenUrl =
        n: "https://${screen n}.${config.shipProxy.domain}/vnc.html?autoconnect=1&resize=scale&show_dot=1";

      # The whole desktop inside: cage with the MCP server as its one app,
      # which launches Brave into the same session.
      guest =
        n:
        let
          mac = "02:00:01:00:00:${fixedWidthString 2 "0" (toString indexed.${n})}";
        in
        {
          config =
            { pkgs, ... }:
            let
              session = {
                XDG_RUNTIME_DIR = "/run/desk";
                WAYLAND_DISPLAY = "wayland-0";
              };
              playwright = import ./playwright-mcp.nix pkgs;
              mcpUrl = "http://localhost:${toString computers.mcpPort}/mcp";
              keeper = pkgs.writers.writePython3Bin "desk-keeper" {
                libraries = singleton pkgs.python3Packages.mcp;
              } (readFile ./yeoman-computer/keeper.py);
              # The headless output starts at wlroots' 1280x720 whatever the
              # viewport, so it is sized to the screen before the browser opens.
              browse = pkgs.writeShellScript "desk-browse" ''
                ${getExe pkgs.wlr-randr} --output HEADLESS-1 --custom-mode ${computers.screen}
                exec ${getExe playwright} "$@"
              '';
              desktop = pkgs.writeShellApplication {
                name = "desk";
                runtimeInputs = [
                  pkgs.cage
                  pkgs.coreutils
                ];
                text = ''
                  install -d -m 0700 /home/pc/profile
                  # The headless wlroots backend needs no GPU or input
                  # device; wayvnc supplies the keyboard and mouse.
                  export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
                  export NIXOS_OZONE_WL=1
                  # The profile goes by environment: the nixpkgs wrapper turns
                  # on isolated mode, which refuses a profile, unless this is set.
                  export PLAYWRIGHT_MCP_USER_DATA_DIR=/home/pc/profile
                  exec cage -- ${browse} \
                    --host 0.0.0.0 --port ${toString computers.mcpPort} \
                    --allowed-hosts ${addr n},${addr n}:${toString computers.mcpPort},localhost,localhost:${toString computers.mcpPort} \
                    --browser chrome --executable-path ${getExe pkgs.brave} --sandbox \
                    --shared-browser-context \
                    --output-dir ${computers.deskMount} \
                    --viewport-size ${computers.screen}
                '';
              };
            in
            {
              # The same Brave as the desktop: its extras, telemetry and
              # password manager off by policy.
              imports = singleton self.nixosModules.brave;

              microvm = {
                hypervisor = "cloud-hypervisor";
                vcpu = 2;
                mem = 4096;
                interfaces = singleton {
                  type = "tap";
                  id = "pc-${n}";
                  inherit mac;
                };
                # Not a share of the live store: host gc would corrupt a
                # running guest.
                storeOnDisk = true;
                # systemd-notify from the guest.
                vsock.cid = 200 + indexed.${n};
                # Kept across starts: the browser profile with its logins.
                volumes = singleton {
                  image = "home.img";
                  mountPoint = "/home/pc";
                  size = 20480;
                };
                shares = singleton {
                  proto = "virtiofs";
                  tag = "desk";
                  source = desk n;
                  mountPoint = computers.deskMount;
                  cache = "never";
                };
              };

              networking = {
                hostName = vm n;
                useNetworkd = true;
                useDHCP = false;
                nameservers = computers.nameservers;
                firewall.allowedTCPPorts = [
                  computers.mcpPort
                  computers.keepPort
                  computers.vncPort
                ];
              };
              systemd.network.networks."20-lan" = {
                matchConfig.Type = "ether";
                address = singleton "${addr n}/24";
                gateway = singleton computers.hostAddr;
              };

              # virtiofs passes ids verbatim: the desk group is pinned to
              # the same gid on host and guest.
              users.groups.desk.gid = computers.deskGid;
              users.users.pc = {
                isNormalUser = true;
                uid = 1000;
                group = "desk";
                home = "/home/pc";
                createHome = false;
              };
              systemd.tmpfiles.rules = singleton "d /home/pc 0700 pc desk -";

              # The browser's clock and locale match the house, as a real
              # computer here would.
              time.timeZone = config.time.timeZone;
              i18n.defaultLocale = config.i18n.defaultLocale;

              fonts.packages = [
                pkgs.noto-fonts
                pkgs.noto-fonts-cjk-sans
                pkgs.noto-fonts-color-emoji
              ];

              systemd.services.desk = {
                description = "The desktop: Brave under cage, driven by Playwright MCP";
                wantedBy = singleton "multi-user.target";
                after = singleton "network.target";
                unitConfig.RequiresMountsFor = [
                  "/home/pc"
                  computers.deskMount
                ];
                environment = session;
                serviceConfig = {
                  User = "pc";
                  Group = "desk";
                  RuntimeDirectory = "desk";
                  RuntimeDirectoryMode = "0700";
                  ExecStart = getExe desktop;
                  Restart = "always";
                  RestartSec = 3;
                };
              };
              systemd.services.desk-keeper = {
                description = "Holds the browser open while the assistant has a lease on it";
                wantedBy = singleton "multi-user.target";
                after = singleton "desk.service";
                requires = singleton "desk.service";
                environment = {
                  DESK_MCP = mcpUrl;
                  DESK_KEEP_PORT = toString computers.keepPort;
                };
                serviceConfig = {
                  User = "pc";
                  Group = "desk";
                  ExecStart = getExe keeper;
                  # The server listens a moment after the desktop starts, and
                  # a dropped session is simply opened again.
                  Restart = "always";
                  RestartSec = 3;
                };
              };
              systemd.services.wayvnc = {
                description = "The same screen over VNC, for the person to take over";
                wantedBy = singleton "multi-user.target";
                after = singleton "desk.service";
                requires = singleton "desk.service";
                environment = session;
                serviceConfig = {
                  User = "pc";
                  Group = "desk";
                  # cage offers only wlr-screencopy, over which wayvnc sends no
                  # cursor image; -r paints the pointer into the frame instead.
                  ExecStart = "${getExe pkgs.wayvnc} -r 0.0.0.0 ${toString computers.vncPort}";
                  # The compositor's socket appears a moment after it starts.
                  Restart = "always";
                  RestartSec = 2;
                };
              };

              # The serial console requires host root to reach.
              services.getty.autologinUser = "root";
              system.stateVersion = "26.05";
            };
        };

      reset =
        n:
        pkgs.writeShellApplication {
          name = "${n}-computer-reset";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.systemd
          ];
          text = ''
            # Back to a clean desk: the profile volume goes, the guest
            # recreates it blank on the next start.
            systemctl stop 'microvm@${vm n}.service'
            rm -f '${config.microvm.stateDir}/${vm n}/home.img'
            systemctl start 'microvm@${vm n}.service'
            echo "${n}'s computer is reset"
          '';
        };
    in
    {
      options.yeoman.instances = mkOption {
        type = types.attrsOf (
          types.submodule {
            options.computer = mkOption {
              type = types.bool;
              default = false;
              description = "Whether the assistant has a computer of its own.";
            };
          }
        );
      };

      config = {
        microvm.vms = owners |> map (n: nameValuePair (vm n) (guest n)) |> listToAttrs;

        users.groups.${computers.deskGroup}.gid = computers.deskGid;
        # The desk is setgid so the guest's files stay the group's, which
        # the assistant on the host is in.
        systemd.tmpfiles.rules =
          singleton "d ${computers.desks} 0751 root root -"
          ++ (
            owners
            |> map (n: [
              "d ${desk n} 2770 root ${computers.deskGroup} -"
              "d ${config.microvm.stateDir}/${vm n} 0755 microvm kvm -"
            ])
            |> concatLists
          );

        environment.systemPackages = owners |> map reset;

        # The screen: noVNC's page and its websocket on loopback, behind
        # the proxy; the assistant hands out the link.
        shipProxy.routes =
          owners |> map (n: nameValuePair (screen n) { port = screenPort n; }) |> listToAttrs;
        systemd.services =
          (
            owners
            |> map (
              n:
              nameValuePair (screen n) {
                description = "${n}'s screen over the tailnet";
                wantedBy = singleton "multi-user.target";
                after = singleton "network.target";
                serviceConfig = lib.ship.hardened.vendor // {
                  DynamicUser = true;
                  ExecStart = "${getExe' pkgs.python3Packages.websockify "websockify"} --web ${pkgs.novnc}/share/webapps/novnc 127.0.0.1:${toString (screenPort n)} ${addr n}:${toString computers.vncPort}";
                  Restart = "always";
                  RestartSec = 5;
                  IPAddressAllow = [
                    "127.0.0.1"
                    (addr n)
                  ];
                  IPAddressDeny = "any";
                };
              }
            )
            |> listToAttrs
          )
          // (
            owners
            |> map (
              n:
              nameValuePair n {
                environment = {
                  YEOMAN_SCREEN = screenUrl n;
                  YEOMAN_SCREEN_SIZE = computers.screen;
                };
              }
            )
            |> listToAttrs
          );
      };
    };
}
