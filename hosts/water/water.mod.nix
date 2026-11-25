# water — Threadripper PRO 9965WX, 96GB RAM, Radeon 7900 XTX.
# Always-on homelab with a manually started desktop session.
{
  self,
  lib,
  ...
}:
{
  perSystem =
    { lib, pkgs, ... }:
    let
      inherit (lib.attrsets) genAttrs;
      inherit (lib.lists) singleton;
      inherit (lib.strings) toJSON;

      water = self.nixosConfigurations.water.config;
      checkedUnits = [
        "suki-core.service"
        "suki-gateway.service"
        "suki-addon-a2a.service"
        "suki-addon-boards.service"
        "suki-addon-files.service"
        "suki-addon-layout.service"
        "suki-addon-lists.service"
        "suki-addon-pages.service"
        "suki-addon-speech.service"
        "suki-ready.service"
        "hippo2-suki.service"
      ];
      manifest = pkgs.writeText "suki-isolation-manifest.json" (toJSON {
        libri_toml = "${water.environment.etc."libri-suki/libri.toml".source}";
        units = genAttrs checkedUnits (u: "${water.systemd.units.${u}.unit}/${u}");
        has_legacy_suki = water.systemd.services ? suki;
        suki_config_tmpfile = water.systemd.tmpfiles.settings.suki-config."/var/lib/suki-config".d or null;
      });
    in
    {
      checks.suki-isolation =
        pkgs.runCommand "suki-isolation-check"
          {
            nativeBuildInputs = singleton pkgs.python3;
          }
          ''
            python3 -I ${./check_suki_isolation.py} ${manifest}
            touch $out
          '';
    };

  imports = lib.lists.singleton (
    lib.ship.host "water" (
      { config, pkgs, ... }:
      let
        inherit (lib.ship) computers fences;
        inherit (lib.ship.topology) seat;
        harnessMemory = {
          high = "44G";
          maximum = "48G";
          swap = "12G";
        };
        seatPath = lib.strings.concatStringsSep ":" [
          "/etc/profiles/per-user/${seat.user}/bin"
          "/run/wrappers/bin"
          "/run/current-system/sw/bin"
        ];
      in
      {
        imports = [
          self.nixosModules.lab
          self.nixosModules.desktop
          self.nixosModules.hyprland
          self.nixosModules.dev
          self.nixosModules.gaming
          self.nixosModules.creative
          self.nixosModules.davinci-resolve
          self.nixosModules.agent-desktops
          self.nixosModules.radeon-7900xtx
          self.nixosModules.inference-radeon-24gb
          self.nixosModules.inference-client
          ./credentials.nix
          ./nas-storage.nix
        ];

        primaryUser = "katara";
        users.users.katara.uid = 1000;

        # The homelab starts at boot; Hyprland starts only after a local login.
        services.displayManager.autoLogin.enable = false;
        kestrel.allowSleep = false;
        kestrel.idle = {
          lockEnabled = true;
          lockMinutes = 10;
          displayOffEnabled = true;
          displayOffMinutes = 10;
        };

        nixpkgs.hostPlatform = "x86_64-linux";

        boot.initrd.availableKernelModules = [
          "nvme"
          "xhci_pci"
          "ahci"
          "usbhid"
          "usb_storage"
          "sd_mod"
        ];
        boot.kernelModules = lib.lists.singleton "kvm-amd";
        hardware.cpu.amd.updateMicrocode = true;
        hardware.enableRedistributableFirmware = true;
        hardware.amdgpu.opencl.enable = true;

        # Builds use every core, at idle priority, and run in a memory fence:
        # past it a build fails, never the services beside it. Jobs are what
        # cost memory: one release rustc of Libri's daemon peaks at 4.4 GB.
        # Eight jobs of six cores fill all 48 threads (jobs × cores, the Nix
        # manual's sizing) and could ask ~35 GB if eight rustc linked at
        # once; the default (48 jobs, each on every core) linked enough Rust
        # at once to thrash the desktop. MemoryHigh slows builds well before
        # the rest of the machine swaps.
        nix.daemonCPUSchedPolicy = "idle";
        nix.daemonIOSchedClass = "idle";
        # Builds keep their eight jobs; the fence is memory. Nix's builds
        # (23.5 GB at their Nov 13 peak) and Libri's workers (capped at 48G
        # below) stay together under the slice's MemoryHigh, past which the
        # kernel throttles everything in work.slice, Libri's daemon with it
        # (the slice reached 61G that night and the page froze). Past
        # MemoryHigh builds slow; past MemoryMax the kernel kills a rustc.
        nix.settings.max-jobs = 8;
        nix.settings.cores = 6;
        systemd.services.nix-daemon.serviceConfig = {
          MemoryHigh = "22G";
          MemoryMax = "28G";
        };
        # Builds and the agents that start them share one budget, so
        # together they can't take the memory the desktop and services
        # need: two flake checks, six rustc and the chats fill RAM and zram
        # and freeze the host. Past MemoryHigh the slice
        # slows; past MemoryMax the kernel kills its largest process (a
        # rustc or an evaluator), not the host. Swap is capped because zram
        # spends RAM too: at the 3.6x zstd ratio Water's zram shows, 16G of
        # swap holds about 4.5G of RAM, so the slice at its MemoryHigh and
        # a full swap still leave the desktop and services 15G.
        systemd.slices.work.sliceConfig = {
          MemoryMin = "1G";
          MemoryHigh = "74G";
          MemoryMax = "80G";
          MemorySwapMax = "16G";
        };
        systemd.services.nix-daemon.serviceConfig.Slice = "work.slice";

        # The chats' own cargo and evaluators run in paseo, outside the
        # daemon's fence; paseo has peaked at 16G with 11G in zram.
        # MemoryHigh only slows it past 24G; no MemoryMax, so a chat is
        # never killed for a build beside it.
        # A deploy never restarts it: that would end every chat and its long
        # runs. A new paseo takes over at the next manual restart or boot.
        systemd.services.paseo = {
          serviceConfig.MemoryHigh = "24G";
          serviceConfig.Slice = "work.slice";
          restartIfChanged = false;
        };
        # Libri's workers run cargo, Gradle and QEMU, so they share that budget:
        # of its 93.7G the slice's 80G leaves the desktop and services 13.7G at
        # the least (4G is what they hold today) and starts slowing the slice
        # at 74G, with zram behind both.
        libri.legacy.enable = false;
        libri.legacySuki.enable = false;
        seat.hippo.enable = false;

        keyProxy.users = [
          seat.user
          "suki"
        ];

        # Stage 2 serves Dylan's address: Bridge's core, gateway (si.su.is and
        # core.su.is), and add-ons on the seat's account.
        libri.assistants.bridge = {
          unitPrefix = "libri";
          description = "Libri core for the seat";
          inherit (seat) user home;
          group = seat.user;
          hippo2Unit = "hippo2.service";
          setSessionVariables = true;

          core = {
            includeSeatMcp = true;
            path = seatPath;
            supplementaryGroups = lib.lists.singleton "usage";
            envCredentials.CLAUDE_CODE_OAUTH_TOKEN = {
              credentialName = "claude-token";
              path = config.secrets.agent-claude-token.path;
            };
            # Mode a child session gets when its parent runs on a different
            # harness: each built-in harness's autonomous widening mode.
            harnesses = {
              claude.child_mode = "bypassPermissions";
              codex.child_mode = "never";
              agy.child_mode = "full-access";
              muse.child_mode = "allowAll";
              omp.child_mode = "full-access";
              opencode.child_mode = "full-access";
              pi.child_mode = "full-access";
            };
            # Workers' processes slow past 44G and are killed past 48G. At 32G,
            # some twenty agents (0.4-1.8G each) with two Gradle builds filled it;
            # 12G of swap takes cold Claude Code heaps and costs at most 3.4G of
            # RAM in zram, staying inside the slice's 16G.
            extraServiceConfig = {
              Slice = "work.slice";
              MemoryHigh = harnessMemory.high;
              MemoryMax = harnessMemory.maximum;
              MemorySwapMax = harnessMemory.swap;
            };
          };

          gateway = {
            enable = true;
            port = 8953;
            subdomain = "si";
            domain = "si.${config.shipProxy.domain}";
            aliases = lib.lists.singleton "core";
            tailnetOwners = lib.lists.singleton "ddcleary1@gmail.com";
            assistantName = "Bridge";
            # Fixed at the UID/GID NixOS first allotted Water (/var/lib/nixos/uid-map),
            # which owns /var/lib/libri-gateway; served add-ons enforce --peer-uid.
            uid = 953;
            gid = 940;
          };

          a2a = {
            enable = true;
            port = 8951;
            peersFile = "/var/lib/libri-core/a2a-peers.json";
            tokenFile = "/var/lib/libri-core/a2a.token";
            name = "Bridge";
            person = "Dylan";
          };

          addons = {
            wiki = {
              enable = true;
              dir = "/var/lib/libri/wiki";
            };
            connect = {
              enable = true;
              dir = "/var/lib/libri/connections";
              servers = lib.lists.singleton "fastmail";
            };
            files = {
              enable = true;
              environment.LIBRI_FILES_DIR = "/var/lib/libri/files";
            };
            lists = {
              enable = true;
              environment.LIBRI_LISTS_DIR = "/var/lib/libri-core/lists";
            };
            boards = {
              enable = true;
              environment.LIBRI_BOARDS_DIR = "/var/lib/libri-core/boards";
            };
            pages = {
              enable = true;
              environment = {
                LIBRI_PAGES_DIR = "/var/lib/libri-core/pages";
                LIBRI_PAGES_DATA_DIR = "/var/lib/libri-core/page-data";
              };
            };
            # The key proxy's sockets: credentials.nix. x_search shares the xAI
            # login under /var/lib/libri/connections and renews it under its lock.
            search = {
              enable = true;
              environment.LIBRI_XAI_CONNECTION = "/var/lib/libri/connections/xai.json";
            };
            # Grok Imagine on the same xAI login as x_search, into the files
            # add-on's folder, so each picture shows in Files and at its raw URL.
            image = {
              enable = true;
              environment = {
                LIBRI_IMAGE_DIR = "/var/lib/libri/files";
                LIBRI_XAI_CONNECTION = "/var/lib/libri/connections/xai.json";
              };
            };
            # On Water's own models: no key, no network.
            speech = {
              enable = true;
              provider = "local";
              environment = {
                LIBRI_SPEECH_DIR = "/var/lib/libri-core/speech";
                LIBRI_SPEECH_INPUT_DIR = "/var/lib/libri/files";
              };
            };
            # Sends wait on the person's approval through the core, on the
            # session's own LIBRI_SOCKET, LIBRI_TOKEN and LIBRI_SESSION. Its key
            # is a file the seat writes before enabling.
            mail = {
              enable = false;
              environment = {
                LIBRI_MAIL_JMAP_URL = "https://api.fastmail.com/jmap/session";
                LIBRI_MAIL_TOKEN_FILE = "/var/lib/libri-core/mail.token";
              };
            };
            layout = {
              enable = true;
              environment.LIBRI_LAYOUT_STATE = "/var/lib/libri-core/layout";
            };
            ui.enable = true;
            a2a = {
              enable = true;
              environment = {
                LIBRI_A2A_NAME = "Bridge";
                LIBRI_A2A_PEERS_FILE = "/var/lib/libri-core/a2a-peers.json";
              };
            };
          };
        };

        services.hippo2.instances.suki = {
          enable = true;
          user = "hippo2-suki";
          group = "hippo2-suki";
          dataDir = "/var/lib/hippo2-suki";
          readers = lib.lists.singleton "suki";
          libriCoreSocket = config.libri.assistants.suki.clientSocketPath;
          libriCoreTokenFile = "/var/lib/hippo2-suki/libri-core.token";
          disabledReaders = [
            "claude-code"
            "codex"
            "omp"
            "opencode"
            "muse"
          ];
        };

        users.groups.hippo2-suki.gid = 938;
        users.users.hippo2-suki = {
          isSystemUser = true;
          uid = 951;
          group = "hippo2-suki";
          extraGroups = lib.lists.singleton config.libri.assistants.suki.clientsGroup;
        };

        # Stage 2 serves Gab's assistant: Suki's core, gateway (suki.su.is),
        # inbound A2A on 127.0.0.1:8952, code runner, and isolated add-ons.
        libri.assistants.suki = {
          unitPrefix = "suki";
          description = "Libri core for Suki";
          user = "suki";
          group = "suki";
          createUser = true;
          # Keep the UID/GID Water first allotted `suki` (/var/lib/nixos/uid-map).
          uid = 970;
          gid = 966;
          userHome = "/var/lib/suki";
          home = "/var/lib/suki-core";
          dataDir = "/var/lib/suki-core";
          runtimeDir = "/run/suki-core";
          systemConfigDir = "/etc/libri-suki";
          configDir = "/var/lib/suki-config";
          hippo2Unit = "hippo2-suki.service";

          core = {
            includeSeatMcp = false;
            path = lib.strings.makeBinPath [
              pkgs.claude-code
              pkgs.coreutils
            ];
            supplementaryGroups = [
              "usage"
              computers.deskGroup
            ];
            extraEnv.HOME = "/var/lib/suki-core";
            envCredentials.ANTHROPIC_API_KEY = {
              credentialName = "claude-key";
              path = config.secrets.suki-claude-key.path;
            };
            authHeaderFiles.home-auth = {
              credentialName = "home";
              path = config.secrets.yeoman-home-token.path;
            };
            harnesses.claude = {
              tools = lib.lists.singleton "AskUserQuestion";
              strict_mcp = true;
            };
            mcpServers = {
              hippo2.command = [
                (lib.meta.getExe config.services.hippo2.instances.suki.finalPackage)
                "mcp"
              ];
              home = {
                url = "http://127.0.0.1:${toString config.shipProxy.routes.ha.port}/api/mcp";
                headers.Authorization.file = "/run/suki-core/home-auth";
              };
              money.url = "http://127.0.0.1:${toString config.money.mcpPort}/mcp";
            };
            extraServiceConfig = lib.ship.hardened.tenant // {
              # SO_PEERCRED / chgrp suki-clients / yeoman-desk virtiofs / hippo2-suki group reads.
              PrivateUsers = false;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
              ReadWritePaths = lib.lists.singleton "${computers.desks}/suki";
              # ONNX Runtime in local libri-speech reads /proc/cpuinfo; owner.sock walks
              # /proc/<pid>/stat up to PID 1 (and sudo/runuser parents) to verify callers.
              ProcSubset = "all";
              ProtectProc = "default";
              IPAddressAllow =
                fences.loopback ++ lib.lists.singleton "${computers.addr computers.indexes.suki}/32";
              IPAddressDeny = fences.internetOnlyDeny ++ lib.lists.singleton "127.0.0.0/8";
              Slice = "work.slice";
              MemoryHigh = "4G";
              MemoryMax = "6G";
            };
          };

          gateway = {
            enable = true;
            port = 8954;
            subdomain = "suki";
            domain = "suki.${config.shipProxy.domain}";
            tailnetOwners = [
              "gabcaminiti10@gmail.com"
              "ddcleary1@gmail.com/metal"
            ];
            assistantName = "Suki";
            uid = 952;
            gid = 939;
          };

          a2a = {
            enable = true;
            port = 8952;
            peersFile = "/var/lib/suki-core/a2a-peers.json";
            tokenFile = "/var/lib/suki-core/a2a.token";
            name = "Suki";
            person = "Gab";
          };

          addons = {
            wiki = {
              enable = true;
              dir = "/var/lib/suki-core/wiki";
            };
            files = {
              enable = true;
              environment.LIBRI_FILES_DIR = "/var/lib/suki-core/files";
            };
            lists = {
              enable = true;
              environment.LIBRI_LISTS_DIR = "/var/lib/suki-core/lists";
            };
            boards = {
              enable = true;
              environment.LIBRI_BOARDS_DIR = "/var/lib/suki-core/boards";
            };
            pages = {
              enable = true;
              environment = {
                LIBRI_PAGES_DIR = "/var/lib/suki-core/pages";
                LIBRI_PAGES_DATA_DIR = "/var/lib/suki-core/page-data";
              };
            };
            search.enable = true;
            yeomanImage = {
              enable = true;
              dir = "/var/lib/suki-core/files";
            };
            speech = {
              enable = true;
              provider = "local";
              environment = {
                LIBRI_SPEECH_DIR = "/var/lib/suki-core/speech";
                LIBRI_SPEECH_INPUT_DIR = "/var/lib/suki-core/files";
              };
            };
            layout = {
              enable = true;
              environment.LIBRI_LAYOUT_STATE = "/var/lib/suki-core/layout";
            };
            ui.enable = true;
            a2a = {
              enable = true;
              environment = {
                LIBRI_A2A_NAME = "Suki";
                LIBRI_A2A_PEERS_FILE = "/var/lib/suki-core/a2a-peers.json";
              };
            };
            computer = {
              enable = true;
              environment = {
                LIBRI_RUN = "http://${computers.addr computers.indexes.suki}:${toString computers.runPort}";
                LIBRI_RUNS_DIR = "${computers.desks}/suki/${computers.runs}";
                LIBRI_FILES_DIR = "/var/lib/suki-core/files";
                LIBRI_OUTBOX_DIR = "/var/lib/suki-core/outbox";
              };
            };
          };
        };
        # Large cores are logged, not kept, and old ones go past 2G in all.
        systemd.coredump.settings.Coredump = {
          ProcessSizeMax = "1G";
          ExternalSizeMax = "1G";
          MaxUse = "2G";
        };

        boot.loader.timeout = 5;

        # Deploys read the NAS mirror, refreshed first, so GitHub being down
        # only means deploying the last commit it saw.
        switcharoo = {
          source = "/srv/storage/git/dycli/monix.git";
          refresh = "git-mirror@dycli-monix.service";
          mustRun = [
            "hippo2.service"
            "hippo2-suki.service"
            "libri-core.service"
            "libri-gateway.service"
            "libri-addon-a2a.service"
            "suki-core.service"
            "suki-gateway.service"
            "suki-addon-a2a.service"
            "nginx.service"
            "tuwunel.service"
          ];
        };

        home-manager.users.katara.wayland.windowManager.hyprland.extraConfig = lib.modules.mkAfter ''
          -- The ASPEED management output otherwise creates an unseen desktop.
          hl.monitor({ output = "VGA-1", disabled = true })
          hl.monitor({ output = "DP-1", mode = "preferred", position = "auto", scale = 1, vrr = 1 })
          -- Auto HDR switches the DP-1 signal on every fullscreen toggle; the
          -- monitor resyncs, blanking the picture and its audio for a second.
          hl.config({ render = { cm_auto_hdr = 0 } })
        '';

        # Steam and its games inherit CCD 3's six cores and their SMT siblings.
        programs.steam.package = pkgs.steam.override {
          extraProfile = ''
            ${lib.meta.getExe' pkgs.util-linux "taskset"} -pc 18-23,42-47 $$ >/dev/null || exit 1
          '';
        };

        programs.gamemode.enable = true;

        # EcoFlow RIVER 3 Plus over USB HID (usbhid-ups, 3746:ffff).
        ups.enable = true;

        # The e-reader cannot join the tailnet and pulls OPDS over the LAN.
        media.calibreWebLan = {
          interface = "enp209s0f0np0";
          subnet = "192.168.1.0/24";
        };

        # The wall frame cannot join the tailnet either. It sits on the
        # IoT VLAN, which OPNsense lets through to hob's port only.
        hob.lan = {
          interface = "enp209s0f0np0";
          subnet = "192.168.30.0/24";
        };

        # Advertised tailnet exit node; "server" enables the forwarding
        # sysctls. Devices opt in per network from the client.
        services.tailscale.useRoutingFeatures = "server";
        services.tailscale.extraSetFlags = lib.lists.singleton "--advertise-exit-node";

        # TPM-sealed key so the host boots headless; a passphrase slot remains
        # for recovery.
        disko.devices.disk.main = {
          device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_with_Heatsink_2TB_S6WRNS0T219958J";
          type = "disk";

          content.type = "gpt";

          content.partitions.boot = {
            priority = 100;
            size = "1G";
            type = "EF00";

            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
            };
          };

          content.partitions.luks = {
            priority = 200;
            size = "100%";

            content = {
              type = "luks";
              name = "cryptroot";

              # Read at format time only; TPM enrollment replaces it.
              passwordFile = "/tmp/luks.key";

              settings = {
                allowDiscards = true;
                crypttabExtraOpts = lib.lists.singleton "tpm2-device=auto";
              };

              content = {
                type = "btrfs";

                # disko ignores mountOptions on the btrfs content level.
                subvolumes."@" = {
                  mountpoint = "/";
                  mountOptions = [
                    "noatime"
                    "compress=zstd"
                  ];
                };
                # The assistants' computers' disks (assistant-network.mod.nix).
                subvolumes."@agents" = {
                  mountpoint = "/var/lib/agents";
                  mountOptions = [
                    "noatime"
                    "compress=zstd"
                  ];
                };
                subvolumes."@models" = {
                  mountpoint = "/var/lib/models";
                  # Model weights do not compress.
                  mountOptions = lib.lists.singleton "noatime";
                };
              };
            };
          };
        };

        # Both installed OS disks use disko's default partition labels.
        fileSystems."/boot".device = lib.modules.mkForce "/dev/disk/by-uuid/019F-151C";
        boot.initrd.luks.devices.cryptroot.device =
          lib.modules.mkForce "/dev/disk/by-uuid/5063270c-0474-4da7-a772-ba2c2a4d8b23";

        system.stateVersion = "26.05";
      }
    )
  );
}
