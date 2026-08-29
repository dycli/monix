# water — Framework Desktop (Strix Halo, 128GB), headless server carrying the
# homelab and ai roles (modules/{homelab,ai}). Tailnet-only except calibre-web
# :8083 on the LAN. BIOS requires AMD SVM and restore-on-AC-power-loss.
{
  self,
  inputs,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "water" ({
      imports = [
        self.nixosModules.lab
        self.nixosModules.desktop
        self.nixosModules.hyprland
        self.nixosModules.dev
        self.nixosModules.gaming
        self.nixosModules.creative
        inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
        ./credentials.nix
      ];

      primaryUser = "katara";
      users.users.katara.uid = 1000;

      # The homelab starts at boot; Hyprland starts only after a local login.
      services.displayManager.autoLogin.enable = false;
      kestrel.allowSleep = false;

      nixpkgs.hostPlatform = "x86_64-linux";

      # CPU, GPU, pstate and microcode come from the nixos-hardware profile.
      boot.initrd.availableKernelModules = [
        "nvme"
        "xhci_pci"
        "thunderbolt"
        "usbhid"
        "usb_storage"
        "sd_mod"
      ];
      boot.kernelModules = lib.lists.singleton "kvm-amd";
      hardware.enableRedistributableFirmware = true;
      hardware.amdgpu.opencl.enable = true;

      programs.gamemode.enable = true;

      # EcoFlow RIVER 3 Plus over USB HID (usbhid-ups, 3746:ffff).
      alerts.ups.enable = true;

      # The e-reader cannot join the tailnet and pulls OPDS over the LAN.
      media.calibreWebLan = {
        interface = "enp191s0";
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

      system.stateVersion = "26.05";
    })
  );
}
