# fw3 — Framework 13 (7040 AMD), the captain's laptop: Hyprland desktop.
{
  self,
  inputs,
  lib,
  ...
}:
{
  imports = lib.lists.singleton (
    lib.ship.host "fw3" (
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        inherit (lib.modules) mkForce;
      in
      {
        imports = [
          self.nixosModules.desktop
          self.nixosModules.hyprland
          inputs.nixos-hardware.nixosModules.framework-13-7040-amd
        ];

        primaryUser = "dylan";

        nixpkgs.hostPlatform = "x86_64-linux";

        # HARDWARE (quirks/power tuning come from the nixos-hardware
        # framework module above)
        boot.initrd.availableKernelModules = [
          "nvme"
          "xhci_pci"
          "thunderbolt"
          "usb_storage"
          "uas"
          "sd_mod"
        ];
        boot.kernelModules = [ "kvm-amd" ];
        hardware.enableRedistributableFirmware = true;
        hardware.cpu.amd.updateMicrocode = true;

        # DISK (WD Black SN850X 2TB). Disko derives the mount config: /boot
        # from the ESP, / from btrfs subvol @ inside LUKS (opened as
        # /dev/mapper/cryptroot).
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

              content = {
                type = "btrfs";
                subvolumes."@" = {
                  mountpoint = "/";
                };
              };
            };
          };
        };

        # POWER (amd_pstate and the amdgpu PSR workaround come from
        # nixos-hardware and are not repeated here)
        boot.kernelPackages = pkgs.linuxPackages_zen;

        boot.kernelParams = [
          "amdgpu.runpm=1"
          "video.use_native_backlight=1"
          "amdgpu.abmlevel=1"
        ];

        boot.kernel.sysctl = {
          "kernel.nmi_watchdog" = 0;
          "kernel.timer_migration" = 1;
        };

        powerManagement.enable = true;
        powerManagement.powertop.enable = true;

        services.logind.settings.Login.HandlePowerKey = "suspend";

        systemd.timers."fwupd-refresh".enable = false;

        # FRAMEWORK QUIRKS
        hardware.framework.enableKmod = mkForce false;
        hardware.sensor.iio.enable = false;
        hardware.fw-fanctrl.enable = true;

        # PERIPHERALS
        hardware.keyboard.zsa.enable = true;

        # SERVICES
        services.syncthing.enable = true;
        services.printing.enable = true;

        # DESKTOP EXTRAS
        programs.steam.enable = true;
        unfreePackages = [
          "steam"
          "steam-unwrapped"
        ];

        # Prism (not the stock launcher) to pin the Minecraft client to the
        # fw0 server's exact version (see modules/server/minecraft.mod.nix).
        # Element for the family Matrix on chat.su.is (see
        # modules/server/matrix.mod.nix).
        environment.systemPackages = [
          pkgs.prismlauncher
          pkgs.element-desktop
        ];

        # USER: login shell is NixOS's default (bash) — a plain POSIX $SHELL
        # for tools that shell out (nvim, lf, tmux). The interactive shell is
        # nushell, launched by ghostty (see ghostty.mod.nix).
        #
        # Change the password by re-running `mkpasswd -m yescrypt` into
        # `agenix -e hosts/fw3/dylan-password.age` and switching
        # (users.mutableUsers = false ships in the users aspect, so `passwd`
        # does not stick; wheel sudo needs a password, SSH keys don't help).
        secrets.dylan-password.file = ./dylan-password.age;
        users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.dylan-password.path;

        system.stateVersion = "26.05";
      }
    )
  );
}
