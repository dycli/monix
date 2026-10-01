{ lib, ... }:
let
  inherit (lib.lists) singleton;
in
{
  # Unlock after the encrypted OS is available; the key never enters the initrd.
  environment.etc."crypttab".text = ''
    nas-storage /dev/disk/by-id/ata-Samsung_SSD_870_EVO_4TB_S6PJNS0W608033T-part1 /var/lib/nas/storage.key luks,discard,nofail
  '';

  fileSystems."/srv/storage" = {
    device = "/dev/mapper/nas-storage";
    fsType = "btrfs";
    options = [
      "subvol=@data"
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=15s"
    ];
  };
  fileSystems."/srv/storage-snapshots" = {
    device = "/dev/mapper/nas-storage";
    fsType = "btrfs";
    options = [
      "subvol=@snapshots"
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=15s"
    ];
  };
  fileSystems."/srv/backup" = {
    device = "/dev/disk/by-id/ata-ST8000DM004-2U9188_ZR12D48Y-part1";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
      "x-systemd.device-timeout=15s"
    ];
  };

  networking.firewall.interfaces.enp209s0f0np0.allowedTCPPorts = singleton 445;
}
