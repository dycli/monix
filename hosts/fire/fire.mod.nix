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
        qwen38 = context: file: {
          inherit context file;
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
          self.nixosModules.paseo
        ];

        # Leave enough VRAM for MTP, Vulkan, and the desktop: Q4 uses 128K,
        # while Q5 trades some context for higher weight precision at 96K.
        inference.models = lib.modules.mkForce {
          "qwen3.8-27b-q4-k-m" = qwen38 131072 "Qwen3.8-27B-Q4_K_M.gguf";
          "qwen3.8-27b-q5-k-s" = qwen38 98304 "Qwen3.8-27B-Q5_K_S.gguf";
        };

        primaryUser = "zuko";

        services.paseo = {
          user = config.primaryUser;
          group = config.users.users.${config.primaryUser}.group;
        };

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

        # DMS owns the rest of the output configuration; this final rule
        # keeps Adaptive Sync enabled on the gaming display.
        home-manager.users.${config.primaryUser}.wayland.windowManager.hyprland.extraConfig =
          lib.modules.mkAfter ''
            hl.monitor({ output = "DP-1", vrr = 1 })
          '';

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
