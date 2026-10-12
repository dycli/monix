# The generated wrapper supplies the layout, OS paths, tools and repository
# environment.
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
umask 077
mkdir -p /var/cache/restic-nas
exec 9>/run/lock/nas-backup.lock
flock 9
mountpoint -q /srv/backup
[[ $(findmnt -nro SOURCE -M /srv/backup) == "$(readlink -f /dev/disk/by-id/ata-ST8000DM004-2U9188_ZR12D48Y-part1)" ]]

if [[ ${1:-} == maintenance ]]; then
  restic forget --group-by host,paths --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
  restic check --read-data-subset=5%
  exit 0
fi
[[ $# == 0 ]] || { echo 'Usage: nas-backup [maintenance]' >&2; exit 1; }
mountpoint -q /srv/storage
mountpoint -q /srv/storage-snapshots
[[ $(findmnt -nro UUID -M /srv/storage) == "$(blkid -s UUID -o value /dev/mapper/nas-storage)" ]]
[[ $(findmnt -nro UUID -M /srv/storage-snapshots) == "$(findmnt -nro UUID -M /srv/storage)" ]]
for i in "${!sources[@]}"; do
  mountpoint -q "${sources[$i]}"
  [[ $(stat -c '%d:%i' "${sources[$i]}") == "$(stat -c '%d:%i' "/srv/storage/${directories[$i]}")" ]]
done
snapshot=/srv/storage-snapshots/nightly
active=()
resume() {
  if ((${#active[@]})); then systemctl start "${active[@]}"; fi
}
trap resume EXIT
if systemctl is-active --quiet immich-server.service; then active+=(immich-server.service); fi
if ((${#active[@]})); then systemctl stop "${active[@]}"; fi
# SQLite databases and their WAL files are captured together by the atomic
# Btrfs snapshot. Immich alone pauses to match its separate PostgreSQL dump.
install -d -m 0700 /srv/storage/.backup-state
runuser -u postgres -- pg_dump --format=custom "$immich_database" > /srv/storage/.backup-state/immich.dump.tmp
mv /srv/storage/.backup-state/immich.dump.tmp /srv/storage/.backup-state/immich.dump
runuser -u postgres -- pg_dumpall --globals-only > /srv/storage/.backup-state/postgres-globals.sql.tmp
mv /srv/storage/.backup-state/postgres-globals.sql.tmp /srv/storage/.backup-state/postgres-globals.sql
cp /etc/nas/layout /srv/storage/.backup-state/layout
readlink -f /run/current-system > /srv/storage/.backup-state/nixos-system
if [[ -e $snapshot ]]; then btrfs subvolume delete "$snapshot"; fi
btrfs filesystem sync /srv/storage
btrfs subvolume snapshot -r /srv/storage "$snapshot"
resume
active=()
trap - EXIT
# The OS subvolume holds the state no rebuild recreates. Nested subvolumes
# stay out of its snapshot by themselves: agents and models by design, and
# /srv, which the install left as one, so /srv gets a snapshot of its own.
os=/var/lib/nas/os-nightly
srv=/var/lib/nas/srv-nightly
for copy in "$os" "$srv"; do
  if [[ -e $copy ]]; then btrfs subvolume delete "$copy"; fi
done
btrfs filesystem sync /
btrfs subvolume snapshot -r / "$os"
btrfs subvolume snapshot -r /srv "$srv"
targets=("$snapshot")
for path in "${os_paths[@]}"; do
  case $path in
    srv/*) copy=$srv/${path#srv/} ;;
    *) copy=$os/$path ;;
  esac
  [[ -d $copy ]] || { echo "missing $path on the OS disk" >&2; exit 1; }
  targets+=("$copy")
done
if [[ ! -f /srv/backup/restic/config ]]; then restic init; fi
restic backup --host water "${targets[@]}"
btrfs subvolume delete "$os" "$srv"
# Recover actual bytes from the repository before recording success.
restic dump latest "$snapshot/.backup-state/restore-probe" > /var/cache/restic-nas/restored-probe
cmp /srv/storage/.backup-state/restore-probe /var/cache/restic-nas/restored-probe
restic dump latest "$snapshot/.backup-state/immich.dump" > /var/cache/restic-nas/restored-immich.dump
cmp "$snapshot/.backup-state/immich.dump" /var/cache/restic-nas/restored-immich.dump
pg_restore --list /var/cache/restic-nas/restored-immich.dump > /dev/null
rm /var/cache/restic-nas/restored-immich.dump
restic check
restic snapshots --latest 1
date --iso-8601=seconds > /var/lib/nas/last-backup-success
