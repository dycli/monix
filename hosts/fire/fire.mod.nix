# fire — gaming desktop: Hyprland like earth, but wall power and a discrete
# Radeon, so none of the laptop's power tuning or Framework quirks apply.
{
  self,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "fire" (
      { config, ... }:
      let
        qwen38 = file: {
          inherit file;
          context = 32768;
          output = 8192;
          flags = [
            "--flash-attn"
            "on"
            "--jinja"
            "--cache-type-k"
            "q8_0"
            "--cache-type-v"
            "q8_0"
            "--spec-type"
            "draft-mtp"
            "--spec-draft-n-max"
            "2"
            "-np"
            "1"
          ];
        };
      in
      {
        imports = [
          self.nixosModules.desktop
          self.nixosModules.hyprland
          self.nixosModules.dev
          self.nixosModules.gaming
          self.nixosModules.inference-backend
          self.nixosModules.inference-client
        ];

        # A 24 GiB 7900 XTX cannot hold Water's Q6 or Q8 plus runtime state.
        # Keep two smaller comparison quants at 32K with Q8 KV cache.
        inference.models = lib.modules.mkForce {
          "qwen3.8-27b-q4-k-m" = qwen38 "Qwen3.8-27B-Q4_K_M.gguf";
          "qwen3.8-27b-q5-k-s" = qwen38 "Qwen3.8-27B-Q5_K_S.gguf";
        };

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
        boot.kernelModules = lib.lists.singleton "kvm-amd";
        hardware.enableRedistributableFirmware = true;
        hardware.cpu.amd.updateMicrocode = true;

        # DISK
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

              # Without discards an SSD under LUKS never learns which blocks
              # are free.
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
        programs.gamemode.enable = true;

        # Rotate with `mkpasswd -m yescrypt` into the .age file;
        # users.mutableUsers = false means `passwd` does not stick.
        secrets.zuko-password.file = ./zuko-password.age;
        users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.zuko-password.path;

        system.stateVersion = "26.05";
      }
    )
  );
}
