# fire — the gaming desktop: Hyprland like earth, but wall power and a
# discrete Radeon, so none of the laptop's power tuning or Framework
# quirks apply.
#
# CPU is assumed AMD (kvm-amd, AMD microcode); flip both if it turns
# out Intel. The GPU needs nothing named here — amdgpu is in-kernel and
# RADV ships in Mesa. LUKS takes a passphrase at the console like
# earth; TPM enrollment can replace it later the way water boots.
{
  self,
  inputs,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "fire" (
      { config, pkgs, ... }:
      {
        imports = [
          self.nixosModules.desktop
          self.nixosModules.hyprland
          self.nixosModules.dev
        ];

        primaryUser = "zuko";

        nixpkgs.hostPlatform = "x86_64-linux";

        # HARDWARE
        boot.initrd.availableKernelModules = [
          "nvme"
          "xhci_pci"
          "ahci"
          "usbhid"
          "usb_storage"
          "sd_mod"
        ];
        boot.kernelModules = [ "kvm-amd" ];
        hardware.enableRedistributableFirmware = true;
        hardware.cpu.amd.updateMicrocode = true;

        boot.kernelPackages = pkgs.linuxPackages_zen;

        # DISK — Samsung 870 EVO 2TB SATA, the machine's sole drive for
        # now (full wipe of the old Fedora install). Same shape as earth:
        # ESP plus btrfs @ inside LUKS.
        disko.devices.disk.main = {
          device = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB_S6PNNS0W206576T";
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

              # The drive does deterministic TRIM; without discards an
              # SSD under LUKS never learns which blocks are free.
              settings.allowDiscards = true;

              content = {
                type = "btrfs";
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
        };

        # SERVICES
        services.syncthing.enable = true;

        # GAMING
        programs.steam.enable = true;
        # Feral gamemode: games request performance governor and niceness
        # for their runtime; inert otherwise.
        programs.gamemode.enable = true;
        unfreePackages = [
          "steam"
          "steam-unwrapped"
        ];

        # Prism pins the Minecraft client to the water server's exact
        # version (see modules/homelab/minecraft.mod.nix).
        environment.systemPackages = [
          pkgs.prismlauncher
          pkgs.heroic
        ];

        # Change the password by re-running `mkpasswd -m yescrypt` into
        # `agenix -e hosts/fire/zuko-password.age` and switching
        # (users.mutableUsers = false ships in the users aspect, so
        # `passwd` does not stick; wheel sudo needs a password, SSH keys
        # don't help).
        secrets.zuko-password.file = ./zuko-password.age;
        users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.zuko-password.path;

        system.stateVersion = "26.05";
      }
    )
  );
}
