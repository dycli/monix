# air — cloud VPS carrying the internet-facing web role (modules/web/sites).
# Public surface is nginx's 80/443 alone; everything else rides the tailnet.
#
# Unprovisioned template: the disk device and firmware below are generic-KVM
# assumptions, and the host key, password secret, tailscale enrollment and
# alert credentials all land at install time.
{ lib, ... }:
{
  imports = lib.lists.singleton (
    lib.ship.host "air" (
      { ... }:
      {
        primaryUser = "ang";

        nixpkgs.hostPlatform = "x86_64-linux";

        sites.enable = true;

        # sshd answers on the trusted tailscale0 only.
        services.openssh.openFirewall = false;

        boot.initrd.availableKernelModules = [
          "virtio_pci"
          "virtio_scsi"
          "virtio_blk"
          "sd_mod"
        ];

        # Unencrypted, unlike the physical hosts: no TPM to seal a key to, and
        # a passphrase would mean console attendance on every reboot.
        disko.devices.disk.main = {
          device = "/dev/vda";
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

          content.partitions.root = {
            priority = 200;
            size = "100%";

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
            };
          };
        };

        system.stateVersion = "26.05";
      }
    )
  );
}
