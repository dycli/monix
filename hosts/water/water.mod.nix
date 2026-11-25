# water — Threadripper PRO 9965WX, 96GB RAM, Radeon 7900 XTX.
# Always-on homelab with a manually started desktop session.
{
  self,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "water" (
      { config, pkgs, ... }:
      let
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
        seat.hippo.enable = false;
        # Pre-link the computer add-on beside Bridge's own so Wave 3 Suki finds
        # it already built under /var/lib/libri-build/addons/computer.
        libri.deploy.extraAddons = lib.lists.singleton "computer";

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
            "libri-core.service"
            "libri-gateway.service"
            "suki.service"
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
