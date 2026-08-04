# water — Framework Desktop (Strix Halo, 128GB), headless server carrying
# the homelab and ai roles (modules/{homelab,ai}).
#
# Tailnet-only except calibre-web :8083 on the LAN (media.calibreWebLan).
# BIOS requires AMD SVM and restore-on-AC-power-loss.
{
  self,
  inputs,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "water" (
      { ... }:
      {
        imports = [
          self.nixosModules.homelab
          self.nixosModules.ai
          self.nixosModules.dev
          inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
          ./credentials.nix
        ];

        primaryUser = "max";

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
        boot.kernelModules = [ "kvm-amd" ];
        hardware.enableRedistributableFirmware = true;

        # EcoFlow RIVER 3 Plus over USB HID (usbhid-ups, 3746:ffff).
        alerts.ups.enable = true;

        # The e-reader cannot join the tailnet and pulls the OPDS feed.
        media.calibreWebLan = {
          interface = "enp191s0";
          subnet = "192.168.1.0/24";
        };

        # btrfs root inside cryptroot; the key is TPM-sealed so the host
        # boots headless, with a passphrase slot for recovery.
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
                crypttabExtraOpts = [ "tpm2-device=auto" ];
              };

              content = {
                type = "btrfs";

                # disko ignores mountOptions set on the btrfs content
                # level; they must go on each subvolume.
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
                  mountOptions = [ "noatime" ];
                };
              };
            };
          };
        };

        system.stateVersion = "26.05";
      }
    )
  );
}
