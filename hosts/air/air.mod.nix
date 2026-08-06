# air — cloud VPS, the internet-facing web host (modules/web/sites)
# replacing the OpenBSD box: dylanc.com, su.is and cleary.org live,
# cleary.is parked. Public surface is nginx's 80/443 alone; everything
# else rides the tailnet.
#
# TEMPLATE — evaluates and builds, but three things wait for the real
# machine at provisioning time (nixos-anywhere --flake .#air against the
# provider's rescue/stock image, which runs disko and installs in one
# pass):
#
#   1. The disk device and firmware below are generic-KVM guesses;
#      confirm /dev/vda and UEFI against the provider, and flip to GRUB
#      (boot.loader.grub.device = "/dev/vda") if it is BIOS-only.
#   2. The new host key goes into keys.nix, then a credentials.nix here
#      declares the primary user's hashedPasswordFile — until that
#      secret exists, sudo has no password to accept and the provider
#      console is the only root path.
#   3. `tailscale up`, then the tailnet policy learns air: the deploy
#      login for site rsync and this host in the admin SSH rule.
#
# Alerts join once the Matrix credentials are re-encrypted to this
# host's key (alerts.enable + credentialsEnvFile in credentials.nix).
{ lib, ... }:
{
  imports = lib.lists.singleton (
    lib.ship.host "air" (
      { ... }:
      {
        primaryUser = "ang";

        nixpkgs.hostPlatform = "x86_64-linux";

        sites.enable = true;

        # Internet-facing box: sshd answers the tailnet only (tailscale0
        # is trusted); port 22 never opens publicly, same as the homelab.
        services.openssh.openFirewall = false;

        # Generic KVM virtio guest.
        boot.initrd.availableKernelModules = [
          "virtio_pci"
          "virtio_scsi"
          "virtio_blk"
          "sd_mod"
        ];

        # Unencrypted, unlike the physical hosts: a VPS has no TPM to
        # seal a key to, and a passphrase would mean console attendance
        # on every provider reboot. The threat LUKS answers (a walked-off
        # disk) is the provider's storage layer here either way.
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

              # disko ignores mountOptions set on the btrfs content
              # level; they must go on each subvolume.
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
