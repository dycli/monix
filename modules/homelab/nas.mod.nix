# The NAS: service data lives on the encrypted Btrfs SSD (hosts/water/
# nas-storage.nix) and is bind-mounted back at each service's own path,
# so no service knows it moved. One Samba share, tailnet-only, exports
# /srv/storage/shared.
#
# Each night the backup pauses only Immich, dumps its PostgreSQL database,
# takes read-only Btrfs snapshots of the SSD and of the OS subvolume (for
# the state still on the OS disk: Matrix, Home Assistant, Minecraft,
# Prowlarr, Seerr, the assistants) and sends both to the encrypted Restic
# repository on the 8-TB HDD. A backup counts only once its own restore
# checks pass; Sunday maintenance prunes and reads back 5% of the data.
# The repository is inside this machine: it covers a dead SSD, not a dead
# machine.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.nas;
  flake.nixosModules.nas =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) genAttrs listToAttrs nameValuePair;
      inherit (lib.lists) concatMap singleton unique;
      inherit (lib.modules) mkForce;
      inherit (lib.strings) concatMapStringsSep concatStringsSep escapeShellArgs;
      layout = import ./nas/layout.nix;
      services = unique (concatMap (item: item.services) layout);

      # State on the OS disk that no rebuild can recreate, relative to /.
      osPaths = [
        "var/lib/private/tuwunel"
        "var/lib/hass"
        "var/lib/private/prowlarr"
        "var/lib/private/seerr"
        "var/lib/sokka"
        "var/lib/suki"
        "var/lib/sokka-pages"
        "srv/minecraft"
      ];

      backup = pkgs.writeShellApplication {
        name = "nas-backup";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.util-linux
          pkgs.systemd
          pkgs.btrfs-progs
          pkgs.restic
          pkgs.diffutils
          config.services.postgresql.package
        ];
        text = ''
          sources=(${escapeShellArgs (map (item: item.path) layout)})
          directories=(${escapeShellArgs (map (item: item.directory) layout)})
          os_paths=(${escapeShellArgs osPaths})
          immich_database=${lib.strings.escapeShellArg config.services.immich.database.name}
          export RESTIC_REPOSITORY=/srv/backup/restic
          export RESTIC_PASSWORD_FILE=/var/lib/nas/restic-password
          export RESTIC_CACHE_DIR=/var/cache/restic-nas
        ''
        + lib.strings.fileContents ./nas/backup.sh;
      };
    in
    {
      environment.systemPackages = [
        backup
        pkgs.restic
      ];
      # Restored alongside the data so a restore knows where each
      # directory belongs.
      environment.etc."nas/layout".text = concatMapStringsSep "\n" (
        item: "${item.path} ${item.directory}"
      ) layout;

      fileSystems = listToAttrs (
        map (
          item:
          nameValuePair item.path {
            device = "/srv/storage/${item.directory}";
            fsType = "none";
            options = [
              "bind"
              "nofail"
              "x-systemd.requires-mounts-for=/srv/storage"
            ];
          }
        ) layout
      );

      services.samba = {
        enable = true;
        nmbd.enable = false;
        winbindd.enable = false;
        openFirewall = false;
        settings = {
          global = {
            "server string" = "Water storage";
            "server min protocol" = "SMB2_10";
            "map to guest" = "Never";
            "hosts allow" = "127.0.0.1 ::1 ${lib.ship.fences.tailnet} fd7a:115c:a1e0::/48";
            "hosts deny" = "ALL";
            "load printers" = "no";
            "printing" = "bsd";
            "printcap name" = "/dev/null";
          };
          storage = {
            path = "/srv/storage/shared";
            "valid users" = config.primaryUser;
            "read only" = "no";
            "guest ok" = "no";
            "create mask" = "0600";
            "directory mask" = "0700";
          };
        };
      };

      systemd.services =
        (genAttrs services (name: {
          unitConfig.RequiresMountsFor = concatStringsSep " " (
            map (item: item.path) (lib.lists.filter (item: lib.lists.elem name item.services) layout)
          );
          bindsTo = singleton "srv-storage.mount";
          after = singleton "srv-storage.mount";
        }))
        // {
          samba-smbd = {
            unitConfig.RequiresMountsFor = mkForce "/var/lib/samba /srv/storage";
            bindsTo = singleton "srv-storage.mount";
            after = singleton "srv-storage.mount";
          };
          nas-backup = {
            description = "Snapshot NAS services and back up to the 8-TB disk";
            unitConfig.ConditionPathExists = "/var/lib/nas/provisioning-complete";
            unitConfig.RequiresMountsFor = "/srv/storage /srv/storage-snapshots /srv/backup";
            after = singleton "postgresql.target";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.meta.getExe backup;
              TimeoutStartSec = "infinity";
              UMask = "0077";
              Nice = 10;
              IOSchedulingClass = "idle";
            };
          };
          nas-backup-maintenance = {
            description = "Prune and check the NAS backup repository";
            unitConfig.ConditionPathExists = "/var/lib/nas/provisioning-complete";
            unitConfig.RequiresMountsFor = "/srv/backup";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.meta.getExe backup} maintenance";
              TimeoutStartSec = "infinity";
              UMask = "0077";
              Nice = 15;
              IOSchedulingClass = "idle";
            };
          };
        };
      systemd.timers.nas-backup = {
        wantedBy = singleton "timers.target";
        timerConfig = {
          OnCalendar = "*-*-* 03:30:00";
          Persistent = true;
        };
      };
      systemd.timers.nas-backup-maintenance = {
        wantedBy = singleton "timers.target";
        timerConfig = {
          OnCalendar = "Sun *-*-* 12:00:00";
          Persistent = true;
        };
      };
    };
}
