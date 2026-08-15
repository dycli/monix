# earth — Framework 13 (7040 AMD) laptop: Hyprland desktop.
{
  self,
  inputs,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "earth" (
      {
        config,
        lib,
        ...
      }:
      let
        inherit (lib.lists) singleton;
        inherit (lib.modules) mkAfter mkForce;
        inherit (lib.trivial) importJSON;
      in
      {
        imports = [
          self.nixosModules.desktop
          self.nixosModules.hyprland
          self.nixosModules.dev
          self.nixosModules.gaming
          inputs.nixos-hardware.nixosModules.framework-13-7040-amd
        ];

        primaryUser = "dylan";

        nixpkgs.hostPlatform = "x86_64-linux";

        # HARDWARE
        boot.initrd.availableKernelModules = [
          "nvme"
          "xhci_pci"
          "thunderbolt"
          "usb_storage"
          "uas"
          "sd_mod"
        ];
        boot.kernelModules = singleton "kvm-amd";
        hardware.enableRedistributableFirmware = true;
        hardware.cpu.amd.updateMicrocode = true;

        # DISK
        disko.devices.disk.main = {
          device = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_24144X801841";
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

        # POWER
        boot.kernelParams = [
          "amdgpu.runpm=1"
          "video.use_native_backlight=1"
          "amdgpu.abmlevel=1"
          # The hibernation swapfile's physical offset (see the swap block).
          "resume_offset=294525629"
        ];

        boot.kernel.sysctl = {
          "kernel.nmi_watchdog" = 0;
          "kernel.timer_migration" = 1;
        };

        powerManagement.enable = true;
        powerManagement.powertop.enable = true;

        networking.networkmanager.wifi.powersave = true;

        # s2idle drains ~1%/hour, so a closed lid suspends, then after two
        # hours writes the image and powers off. The swapfile below backs
        # the image (NoCOW, created by the swap unit on btrfs); the offset
        # is its physical position from
        # `btrfs inspect-internal map-swapfile -r /swap` — re-derive it if
        # the file is ever recreated.
        swapDevices = singleton {
          device = "/swap";
          size = 32768;
        };
        boot.resumeDevice = "/dev/mapper/cryptroot";
        systemd.sleep.settings.Sleep.HibernateDelaySec = "2h";

        services.logind.settings.Login.HandlePowerKey = "suspend";
        services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";

        # FRAMEWORK QUIRKS
        hardware.framework.enableKmod = mkForce false;
        hardware.sensor.iio.enable = false;
        hardware.fw-fanctrl.enable = true;

        # PERIPHERALS
        hardware.keyboard.zsa.enable = true;

        # AUDIO + DISPLAY CALIBRATION
        home-manager.users.${config.primaryUser} = {
          services.easyeffects = {
            enable = true;
            preset = "fw13";
            extraPresets.fw13 = importJSON ./fw13-easy-effects.json;
          };
          xdg.dataFile."easyeffects/irs/IR_22ms_27dB_5t_15s_0c.irs".source = ./IR_22ms_27dB_5t_15s_0c.irs;

          # i1Pro 2 profile for the 2.8K panel (EDID id BOE0CB4). DMS owns
          # dms/outputs.lua but its writer cannot express icc; mkAfter lands
          # this after the dms.outputs require, and the last rule for an
          # output wins. Scale 2 matches the session's static GDK_SCALE.
          wayland.windowManager.hyprland.extraConfig = mkAfter ''
            hl.monitor({ output = "eDP-1", mode = "2880x1920@120", position = "auto", scale = 2, icc = "${./BOE0CB4.icc}" })
          '';
        };

        # SERVICES
        services.syncthing.enable = true;
        services.printing.enable = true;

        # Rotate with `mkpasswd -m yescrypt` into the .age file;
        # users.mutableUsers = false means `passwd` does not stick.
        secrets.dylan-password.file = ./dylan-password.age;
        users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.dylan-password.path;

        system.stateVersion = "26.05";
      }
    )
  );
}
