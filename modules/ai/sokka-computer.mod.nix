# Each assistant's own computer: a persistent microVM with a desktop that
# only it touches. Brave runs full screen under cage on a headless
# wlroots output, driven by Playwright MCP over HTTP on the guest's
# address, and wayvnc shows the same screen so the person can take over
# (captcha, two-factor) from a viewer on the host. The browser profile
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
# network is the internet only (sokka-network.mod.nix).
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.sokka-computer;
  flake.nixosModules.sokka-computer =
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
      inherit (lib) types;
      inherit (lib.ship) computers;

      indexed = computers.indexes config.sokka.instances;
      owners = attrNames indexed;
      addr = n: computers.addr indexed.${n};

      vm = n: "${n}-pc";
      desk = n: "${computers.desks}/${n}";
      screenPort = n: computers.screenPort indexed.${n};
      screen = n: "${n}-screen";
      screenUrl = n: "https://${screen n}.${config.shipProxy.domain}/vnc.html?autoconnect=1&resize=scale";

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
                  exec cage -- ${getExe playwright} \
                    --host 0.0.0.0 --port ${toString computers.mcpPort} \
                    --allowed-hosts ${addr n},${addr n}:${toString computers.mcpPort},localhost \
                    --browser chrome --executable-path ${getExe pkgs.brave} --sandbox \
                    --user-data-dir /home/pc/profile --shared-browser-context \
                    --output-dir ${computers.deskMount} \
                    --viewport-size ${computers.screen}
                '';
              };
            in
            {
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
                # systemd-notify from the guest; drones take 100 and up.
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
              systemd.services.wayvnc = {
                description = "The same screen over VNC, for the person to take over";
                wantedBy = singleton "multi-user.target";
                after = singleton "desk.service";
                requires = singleton "desk.service";
                environment = session;
                serviceConfig = {
                  User = "pc";
                  Group = "desk";
                  ExecStart = "${getExe pkgs.wayvnc} 0.0.0.0 ${toString computers.vncPort}";
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
      options.sokka.instances = mkOption {
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
          // (owners |> map (n: nameValuePair n { environment.SOKKA_SCREEN = screenUrl n; }) |> listToAttrs);
      };
    };
}
