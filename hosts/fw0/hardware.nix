{ lib, ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";

  # CPU/GPU/pstate/microcode come from the nixos-hardware profile. This
  # kernel-module list was generated on the machine.
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
  networking.useDHCP = lib.mkDefault true;

  # The btrfs root lives inside cryptroot. Its key is sealed into the TPM so
  # the host auto-boots headless; a passphrase slot remains for recovery.
  boot.initrd.systemd.enable = true;

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

        # Read only at format time; never committed. TPM enrollment replaces
        # this temporary recovery passphrase as the normal unlock path.
        passwordFile = "/tmp/luks.key";

        settings = {
          allowDiscards = true;
          crypttabExtraOpts = [ "tpm2-device=auto" ];
        };

        content = {
          type = "btrfs";

          # Separate agent state and model weights from the root dataset.
          subvolumes."@".mountpoint = "/";
          subvolumes."@agents".mountpoint = "/var/lib/agents";
          subvolumes."@models".mountpoint = "/var/lib/models";
        };
      };
    };
  };

  # Coarse resource fences prevent any tenant from starving another.
  systemd.slices.agents.sliceConfig.MemoryMax = "48G";
  systemd.slices.inference.sliceConfig.MemoryMax = "96G";
  systemd.slices.services.sliceConfig.MemoryMax = "16G";
}
