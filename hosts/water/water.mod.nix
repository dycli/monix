# water — Threadripper PRO 9965WX, 32GB RAM, Radeon 7900 XTX.
# Always-on homelab with a manually started desktop session.
{
  self,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "water" (
      { pkgs, ... }: {
        imports = [
          self.nixosModules.lab
          self.nixosModules.desktop
          self.nixosModules.hyprland
          self.nixosModules.dev
          self.nixosModules.gaming
          self.nixosModules.creative
          self.nixosModules.davinci-resolve
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
        # past it a build fails, never the services beside it.
        nix.daemonCPUSchedPolicy = "idle";
        nix.daemonIOSchedClass = "idle";
        systemd.services.nix-daemon.serviceConfig = {
          MemoryHigh = "18G";
          MemoryMax = "22G";
        };

        boot.loader.timeout = 5;

        home-manager.users.katara.wayland.windowManager.hyprland.extraConfig = lib.modules.mkAfter ''
          -- The ASPEED management output otherwise creates an unseen desktop.
          hl.monitor({ output = "VGA-1", disabled = true })
          hl.monitor({ output = "DP-1", mode = "preferred", position = "auto", scale = 1, vrr = 1 })
        '';

        # Steam and its games inherit CCD 3's six cores and their SMT siblings.
        programs.steam.package = pkgs.steam.override {
          extraProfile = ''
            ${lib.meta.getExe' pkgs.util-linux "taskset"} -pc 18-23,42-47 $$ >/dev/null || exit 1
          '';
        };

        programs.gamemode.enable = true;

        # EcoFlow RIVER 3 Plus over USB HID (usbhid-ups, 3746:ffff).
        alerts.ups.enable = true;

        # Air's tailnet address; its alerts reach Sokka through here.
        alerts.relay.from = lib.lists.singleton "100.107.48.89";

        # The e-reader cannot join the tailnet and pulls OPDS over the LAN.
        media.calibreWebLan = {
          interface = "enp209s0f0np0";
          subnet = "192.168.1.0/24";
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
