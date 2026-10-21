# Each assistant's computer for code: a microVM that runs Python with the
# usual data libraries and a shell with file converters, in a folder of
# the desk the host fills with the files it needs and keeps what it
# writes. The runner has no network at all; the guest's own network is
# the internet only (yeoman-network.mod.nix), and nothing of the
# household is in it: no tailnet, no store share, no secret. The
# assistant's browser is not here but on the host (assistant-browser.mod.nix),
# where the GPU draws it.
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
      inherit (lib.meta) getExe;
      inherit (lib.options) mkOption;
      inherit (lib.strings) fixedWidthString;
      inherit (lib) readFile types;
      inherit (lib.ship) computers;

      indexed = computers.indexes config.yeoman.instances;
      owners = attrNames indexed;
      addr = n: computers.addr indexed.${n};

      vm = n: "${n}-pc";
      desk = n: "${computers.desks}/${n}";

      guest =
        n:
        let
          mac = "02:00:01:00:00:${fixedWidthString 2 "0" (toString indexed.${n})}";
        in
        {
          config =
            { pkgs, ... }:
            let
              runner = pkgs.writers.writePython3Bin "desk-runner" { } (readFile ./yeoman-computer/runner.py);
              # What the code has to hand: the data libraries for Python,
              # and converters for pictures, sound and film, documents and
              # archives for the shell.
              tools = [
                (pkgs.python3.withPackages (
                  ps: with ps; [
                    matplotlib
                    numpy
                    openpyxl
                    pandas
                    pillow
                    pillow-heif
                    pypdf
                    python-docx
                    reportlab
                  ]
                ))
                pkgs.bash
                pkgs.coreutils
                pkgs.file
                pkgs.findutils
                pkgs.gawk
                pkgs.gnugrep
                pkgs.gnused
                pkgs.gnutar
                pkgs.gzip
                pkgs.ffmpeg-headless
                pkgs.imagemagick
                pkgs.ghostscript
                pkgs.jq
                pkgs.p7zip
                pkgs.pandoc
                pkgs.poppler-utils
                pkgs.qpdf
                pkgs.unzip
                pkgs.xz
                pkgs.zip
                pkgs.zstd
              ];
            in
            {
              microvm = {
                hypervisor = "cloud-hypervisor";
                vcpu = 2;
                # The runner's 2G and the guest's own.
                mem = 2560;
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
                firewall.allowedTCPPorts = singleton computers.runPort;
              };
              systemd.network.networks."20-lan" = {
                matchConfig.Type = "ether";
                address = singleton "${addr n}/24";
                gateway = singleton computers.hostAddr;
              };

              # virtiofs passes ids verbatim: the desk group is pinned to
              # the same gid on host and guest.
              users.groups.desk.gid = computers.deskGid;
              users.users.run = {
                isSystemUser = true;
                uid = 1001;
                group = "desk";
              };
              # The code's clock and locale match the house.
              time.timeZone = config.time.timeZone;
              i18n.defaultLocale = config.i18n.defaultLocale;

              fonts.packages = [
                pkgs.noto-fonts
                pkgs.noto-fonts-cjk-sans
                pkgs.noto-fonts-color-emoji
              ];

              # systemd holds the socket, so the runner itself can live
              # without a network.
              systemd.sockets.desk-runner = {
                wantedBy = singleton "sockets.target";
                listenStreams = singleton (toString computers.runPort);
              };
              systemd.services.desk-runner = {
                description = "Runs the assistant's code, with no network";
                unitConfig.RequiresMountsFor = singleton computers.deskMount;
                path = tools;
                environment.DESK_RUNS = "${computers.deskMount}/${computers.runs}";
                serviceConfig = {
                  User = "run";
                  Group = "desk";
                  ExecStart = getExe runner;
                  PrivateNetwork = true;
                  PrivateTmp = true;
                  ProtectHome = true;
                  ProtectSystem = "strict";
                  ReadWritePaths = singleton "${computers.deskMount}/${computers.runs}";
                  NoNewPrivileges = true;
                  # Room for a big picture or table.
                  MemoryMax = "2G";
                  TasksMax = 256;
                };
              };

              # The serial console requires host root to reach.
              services.getty.autologinUser = "root";
              system.stateVersion = "26.05";
            };
        };
    in
    {
      options.yeoman.instances = mkOption {
        type = types.attrsOf (
          types.submodule {
            options.computer = mkOption {
              type = types.bool;
              default = false;
              description = "Whether the assistant has a browser and a computer for code of its own.";
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
              "d ${desk n}/${computers.runs} 2770 root ${computers.deskGroup} -"
              "d ${config.microvm.stateDir}/${vm n} 0755 microvm kvm -"
            ])
            |> concatLists
          );
      };
    };
}
