# Water NAS

The 4-TB Samsung 870 EVO (S6PJNS0W608033T) holds an encrypted Btrfs data
filesystem. The 8-TB Seagate (ZR12D48Y) holds an ext4 filesystem with an
encrypted Restic repository. The OS NVMe and 2-TB Fire fallback SSD are excluded
from provisioning. Device paths use serial numbers rather than disk letters.

`layout.nix` defines the data moved onto the SSD. Bind mounts preserve each
service's existing path, ownership and configuration. Media downloads and the
library remain on one filesystem so hard links work. PostgreSQL stays on the
OS disk; every NAS backup includes a consistent Immich database dump and roles.
Prowlarr's indexer configuration, unrelated services and home directories are
outside this NAS backup's scope.

## First setup

Build both `nixosConfigurations.water.config.system.build.prepareNas` and
`nixosConfigurations.water.config.system.build.toplevel`. As root, run
`prepare-water-nas /nix/store/...-nixos-system-water-...` using those two outputs.
Do not activate the NAS configuration separately before provisioning.

The script checks the hostname, OS filesystem UUID, source paths, exact drive
serials and sizes. It unmounts the old desktop mounts without forcing a busy
mount, then formats only the two authorized drives. A persistent marker and a
process lock prevent accidental repeated formatting. If setup fails after it
starts, inspect the error and current mounts; do not remove the marker and rerun.

The bulk copy happens online. The final sync stops the media, photo and camera
services from `layout.nix`, preserving the list that was running. Rsync preserves
ownership, ACLs, extended attributes and hard links, verifies transferred data,
and performs a dry-run reconciliation before activation. A stop timeout is only
accepted when the unit has no remaining processes. Services resume after the
new mounts and configuration take effect. Their original directories remain on
the OS filesystem underneath the bind mounts; setup does not delete them.

The first backup must finish and its restore checks must pass before the
scheduled jobs are enabled. Finally, `smbpasswd` asks for katara's SMB password.
Connect to `smb://water/Storage` over Tailscale or `smb://192.168.1.114/Storage`
on the LAN. Only `/srv/storage/shared` is exported; application data is private.

Copy `/home/katara/water-nas-recovery.tar.gz` to a safe place **off this machine**.
It contains the SSD key, LUKS header, backup password and recovery commands.
Treat it as a password: anyone with the bundle and the disks can read the data.
The OS key files are root-only and are never placed in the Nix store or initrd.

## Backups

At 03:30 each day, the backup checks the actual mounted disks and bind mounts.
It pauses only the Immich server, dumps its PostgreSQL database and roles, takes
a read-only Btrfs snapshot, and immediately resumes Immich. An exit trap also
resumes it if the dump or snapshot fails. Media playback and camera recording
continue; SQLite databases and WAL files are captured together in the atomic
snapshot and recover as after a crash.

Restic copies the snapshot to the HDD. Each successful backup recovers a probe
file and the complete Immich dump, compares their bytes, parses the recovered
dump, and checks repository metadata. This verifies recovery from the repository,
not a full service rebuild. Sunday noon maintenance keeps 7 daily, 4 weekly and
3 monthly restore points, prunes unreferenced data, and reads 5% of stored data.
Both jobs share a lock. Failures use the existing service-failure alerts.

Camera footage shares the retention policy: footage deleted by Frigate can
remain in older backups. Monitor available space on the HDD. The local Btrfs
snapshot is replaced each day; it is not a second independent backup. A backup
inside this machine does not protect against loss of the whole machine.

Run `sudo systemctl start nas-backup.service` for a manual backup, and inspect
`journalctl -u nas-backup.service`. `/var/lib/nas/last-backup-success` records only
a backup whose restore checks passed. A failed job never advances that marker.

## Recovery and retained originals

Recovery commands are also in the private recovery bundle. Restic restores files
under `srv/storage-snapshots/nightly/` inside the chosen restore destination.
`.backup-state/layout` maps directories back to service paths; `immich.dump` is
for `pg_restore`, and `postgres-globals.sql` contains roles. Stop the affected
services and use compatible PostgreSQL and application versions before restoring.

To inspect the retained OS originals without disturbing live mounts, as root:

```sh
mkdir -p /mnt/nas-originals
mount --bind / /mnt/nas-originals
```

Use a plain bind, not a recursive bind: the originals then appear under
`/mnt/nas-originals/srv/media`, `/mnt/nas-originals/srv/photos`, and the relevant
`/mnt/nas-originals/var/lib` directories. Unmount after inspection. Do not delete
these copies until the migrated services and backups have been checked live.
They stop updating at cutover and are not a current backup.

The previous system is retained at `/var/lib/nas/previous-system-root`. A rollback
requires stopping the affected services, removing their NAS bind mounts and
switching to that saved system. Returning to the old originals discards access
to post-migration changes unless those changes are first copied back; do not
perform an automatic rollback over newer data.
