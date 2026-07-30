# fw0 — Framework Desktop (Strix Halo, 128GB unified LPDDR5X), headless
# always-on AI server. Roles: agent-fleet microVM host, cockpit session,
# local inference. Admin and service access is tailnet-only, with exactly
# ONE inbound port on the home LAN: calibre-web :8083, opened for the OPDS
# e-reader that cannot join the tailnet (media.calibreWebLan — see the LAN
# EXCEPTION note in media.mod.nix). Nothing is exposed to the internet.
#
# BIOS (one-time, manual): enable AMD SVM and "restore on AC power loss" so
# the host auto-boots after an outage.
{
  self,
  inputs,
  lib,
  ...
}:
{
  flake.nixosConfigurations.fw0 = lib.nixosSystem {
    modules = [
      (
        { lib, ... }:
        let
          inherit (lib.attrsets) attrValues;
        in
        {
          imports = attrValues self.nixosModules ++ [
            inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
            ./services.nix
          ];

          # HOST CLASS
          networking.hostName = "fw0";
          # Server: isDesktop defaults false, stated for clarity.
          isDesktop = false;
          primaryUser = "max";

          nixpkgs.hostPlatform = "x86_64-linux";

          # HARDWARE (CPU/GPU/pstate/microcode come from the nixos-hardware
          # profile above)
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

          # DISK. btrfs root lives inside cryptroot; key sealed into the TPM
          # so the host auto-boots headless, with a passphrase slot for
          # recovery.
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

                # Read only at format time, never committed; TPM enrollment
                # replaces this as the normal unlock path.
                passwordFile = "/tmp/luks.key";

                settings = {
                  allowDiscards = true;
                  crypttabExtraOpts = [ "tpm2-device=auto" ];
                };

                content = {
                  type = "btrfs";

                  # noatime: on a copy-on-write filesystem every READ
                  # otherwise causes a metadata WRITE to update the access
                  # time, which nothing here consults. compress=zstd uses
                  # btrfs's own heuristics, so it skips data that will not
                  # compress (the media library is already-compressed video)
                  # and wins on service state, databases and logs. These are
                  # MOUNT options: they take effect at the next REBOOT, and
                  # compression applies only to newly written data.
                  #
                  # Per subvolume, not on the parent — disko ignores
                  # mountOptions at the btrfs content level, silently, which
                  # is a no-op that looks like a change.
                  # Agent state and model weights get their own subvolumes.
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
                    # Model weights are incompressible; noatime still helps.
                    mountOptions = [ "noatime" ];
                  };
                };
              };
            };
          };

          # TENANCY. Per-tenant memory ceilings, intentionally overcommitted
          # (normal peaks don't coincide); lower these if concurrent
          # workloads approach physical memory.
          systemd.slices.agents.sliceConfig.MemoryMax = "48G";
          systemd.slices.inference.sliceConfig.MemoryMax = "96G";
          systemd.slices.services.sliceConfig.MemoryMax = "16G";

          system.stateVersion = "26.05";
        }
      )
    ];
  };
}
