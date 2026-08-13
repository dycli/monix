# air — cloud VPS carrying the internet-facing web role (modules/web/sites).
# Public surface is nginx's 80/443 alone; everything else rides the tailnet.
#
# Vultr cloud instance, installed via nixos-anywhere from the live ISO.
# Tailscale enrollment and alert credentials are provisioned out of band,
# not by the flake.
{ lib, ... }:
{
  imports = lib.lists.singleton (
    lib.ship.host "air" (
      { config, ... }:
      {
        primaryUser = "aang";

        # Rotate with `mkpasswd -m yescrypt` into the .age file.
        secrets.aang-password.file = ./aang-password.age;
        users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.aang-password.path;

        nixpkgs.hostPlatform = "x86_64-linux";

        sites.enable = true;

        # sshd answers on the trusted tailscale0 only.
        services.openssh.openFirewall = false;

        # Advertised tailnet exit node; "server" enables the forwarding
        # sysctls. Devices opt in per network from the client.
        services.tailscale.useRoutingFeatures = "server";
        services.tailscale.extraSetFlags = [
          "--advertise-exit-node"
          # Resolve through the local unbound rather than the tailnet's
          # global nameserver, which points back at this host.
          "--accept-dns=false"
        ];

        # The tailnet's global nameserver and the home router's forwarder
        # both point at these addresses.
        resolver.enable = true;
        resolver.addresses = [
          "100.107.48.89"
          "fd7a:115c:a1e0::5436:305b"
        ];

        # Vultr instances boot SeaBIOS, so grub carries the BIOS-boot
        # partition below; /boot lives on the root btrfs.
        boot.loader.systemd-boot.enable = false;
        boot.loader.grub.enable = true;

        # 1 GB of RAM: zram (core default) takes the pressure first, the
        # on-disk file (NoCOW, created by the swap unit on btrfs) is the
        # overflow.
        swapDevices = lib.lists.singleton {
          device = "/swap";
          size = 2048;
        };

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
            size = "1M";
            type = "EF02";
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
