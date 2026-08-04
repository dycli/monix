# fire — the gaming desktop: Hyprland like earth, but wall power and a
# discrete Radeon, so none of the laptop's power tuning or Framework
# quirks apply.
#
# TEMPLATE — evaluates and builds, but the machine-specific facts below
# are placeholders until the hardware is in hand:
#
#   1. The disk device is a stand-in; put the real /dev/disk/by-id path
#      in before running disko (it formats what it is pointed at).
#   2. CPU is assumed AMD (kvm-amd, AMD microcode); flip both if it
#      turns out Intel. The GPU needs nothing named here — amdgpu is
#      in-kernel and RADV ships in Mesa.
#   3. After install: host key into keys.nix, then
#      `agenix -e hosts/fire/dylan-password.age` (rekeyed in
#      secrets.nix) — until then sudo has no password to accept.
#      LUKS below takes a passphrase at the console like earth; TPM
#      enrollment can replace it later the way water boots.
{
  self,
  inputs,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "fire" (
      { pkgs, ... }:
      {
        imports = [
          self.nixosModules.desktop
          self.nixosModules.hyprland
          self.nixosModules.dev
        ];

        primaryUser = "dylan";

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

        # DISK — placeholder device (see TEMPLATE note 1). Same shape as
        # earth: ESP plus btrfs @ inside LUKS.
        disko.devices.disk.main = {
          device = "/dev/disk/by-id/CHANGE-ME-BEFORE-DISKO";
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

        system.stateVersion = "26.05";
      }
    )
  );
}
