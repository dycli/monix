{ self, ... }:
{
  perSystem = { pkgs, ... }: {
    checks.nas-failure-paths =
      pkgs.runCommand "nas-failure-paths"
        {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.bash
            pkgs.coreutils
            pkgs.util-linux
          ];
        }
        ''
          python3 ${./nas}/test_failure_paths.py
          touch $out
        '';
  };

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
      inherit (lib.strings)
        concatMapStringsSep
        concatStringsSep
        escapeShellArg
        escapeShellArgs
        ;
      layout = import ./nas/layout.nix;
      services = unique (concatMap (item: item.services) layout);
      layoutEnvironment = ''
        sources=(${escapeShellArgs (map (item: item.path) layout)})
        directories=(${escapeShellArgs (map (item: item.directory) layout)})
      '';
      runtimeInputs = [
        pkgs.coreutils
        pkgs.nix
        pkgs.kmod
        pkgs.util-linux
        pkgs.systemd
        pkgs.btrfs-progs
        pkgs.cryptsetup
        pkgs.parted
        pkgs.e2fsprogs
        pkgs.rsync
        pkgs.restic
        pkgs.gnutar
        pkgs.gzip
        pkgs.findutils
        pkgs.gnugrep
        pkgs.jq
        config.services.postgresql.package
        config.services.samba.package
      ];
      backup = pkgs.writeShellApplication {
        name = "nas-backup";
        inherit runtimeInputs;
        text =
          layoutEnvironment
          + ''
            immich_database=${escapeShellArg config.services.immich.database.name}
            export RESTIC_REPOSITORY=/srv/backup/restic
            export RESTIC_PASSWORD_FILE=/var/lib/nas/restic-password
            export RESTIC_CACHE_DIR=/var/cache/restic-nas
          ''
          + lib.strings.fileContents ./nas/backup.sh;
      };
      migrationEnvironment = layoutEnvironment + ''
        consumers=(${escapeShellArgs (map (name: "${name}.service") services)})
        primary_user=${escapeShellArg config.primaryUser}
      '';
      prepare = pkgs.writeShellApplication {
        name = "prepare-water-nas";
        runtimeInputs = runtimeInputs ++ singleton backup;
        text =
          migrationEnvironment
          + lib.strings.fileContents ./nas/prepare.sh
          + "\n"
          + lib.strings.fileContents ./nas/finish.sh;
      };
      resume = pkgs.writeShellApplication {
        name = "resume-water-nas";
        runtimeInputs = runtimeInputs ++ singleton backup;
        text =
          migrationEnvironment
          + lib.strings.fileContents ./nas/resume.sh
          + "\n"
          + lib.strings.fileContents ./nas/finish.sh;
      };
    in
    {
      system.build.prepareNas = prepare;
      system.build.resumeNas = resume;
      environment.systemPackages = [
        backup
        pkgs.restic
      ];
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
            "hosts allow" = "127.0.0.1 ::1 192.168.1.0/24 100.64.0.0/10 fd7a:115c:a1e0::/48";
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
