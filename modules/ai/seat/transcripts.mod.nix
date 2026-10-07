# TRANSCRIPT ARCHIVE
# Every agent harness prunes or deletes its own session logs. Root copies the
# seat's into the NAS, which the nightly Restic run backs up, and never
# deletes. hippo, the planned memory, will read it.
{
  flake.nixosModules.seat =
    { lib, pkgs, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.strings) escapeShellArg;
      inherit (lib.ship.topology) seat;

      archive = pkgs.writeShellApplication {
        name = "archive-transcripts";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.rsync
          pkgs.sqlite
          pkgs.util-linux
        ];
        text = ''
          home=${escapeShellArg seat.home}
          archive=${escapeShellArg seat.transcripts}
          group=${escapeShellArg seat.user}
        ''
        + lib.strings.fileContents ./transcripts.sh;
      };
    in
    {
      systemd.services.archive-transcripts = {
        description = "Copy the AI seat's agent transcripts into the NAS";
        unitConfig.RequiresMountsFor = "/srv/storage";
        serviceConfig = lib.ship.hardened.tenant // {
          Type = "oneshot";
          ExecStart = lib.meta.getExe archive;
          # Root without PrivateUsers, keeping only what reading the seat's
          # private directories, handing files to its group and querying
          # OpenCode as the seat need.
          PrivateUsers = false;
          CapabilityBoundingSet = [
            "CAP_DAC_READ_SEARCH"
            "CAP_CHOWN"
            "CAP_SETUID"
            "CAP_SETGID"
          ];
          ProtectHome = "read-only";
          # SQLite needs the WAL index writable even to read.
          ReadWritePaths = [
            "/srv/storage"
            "-${seat.home}/.local/share/opencode"
          ];
          PrivateNetwork = true;
          RestrictAddressFamilies = "none";
          UMask = "0027";
          Nice = 15;
          IOSchedulingClass = "idle";
        };
      };

      systemd.timers.archive-transcripts = {
        wantedBy = singleton "timers.target";
        timerConfig = {
          OnCalendar = "*:0/10";
          Persistent = true;
        };
      };
    };
}
