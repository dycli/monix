# Deliberately only these two serial-numbered disks; never the OS or Fire fallback.
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
exec 8>/run/lock/nas-provision.lock
flock -n 8
[[ $# == 1 && -x $1/bin/switch-to-configuration ]] || { echo 'Usage: prepare-water-nas /nix/store/...-nixos-system-water-...' >&2; exit 1; }
new_system=$(readlink -f "$1")
[[ $(hostname) == water ]]
[[ $(findmnt -nro UUID /) == d678129c-2832-4ae7-b376-dfddf615654f ]]
[[ -f $new_system/etc/nas/layout ]]
[[ ! -e /var/lib/nas/provisioning-started ]] || { echo 'Provisioning already started. Inspect its state; refusing to reformat.' >&2; exit 1; }
[[ ! -e /var/lib/nas/storage.key && ! -e /var/lib/nas/restic-password ]]
ssd=/dev/disk/by-id/ata-Samsung_SSD_870_EVO_4TB_S6PJNS0W608033T
hdd=/dev/disk/by-id/ata-ST8000DM004-2U9188_ZR12D48Y
[[ $(lsblk -dnro SERIAL "$ssd") == S6PJNS0W608033T ]]
[[ $(lsblk -dnro SERIAL "$hdd") == ZR12D48Y ]]
[[ $(lsblk -bdnro SIZE "$ssd") == 4000787030016 ]]
[[ $(lsblk -bdnro SIZE "$hdd") == 8001563222016 ]]
for path in "${sources[@]}"; do
  [[ -d $path && ! -L $path ]]
  if mountpoint -q "$path"; then echo "Already mounted: $path; refusing migration." >&2; exit 1; fi
  [[ $(findmnt -nro UUID -T "$path") == d678129c-2832-4ae7-b376-dfddf615654f ]]
done
for path in /srv/storage /srv/storage-snapshots /srv/backup; do
  if mountpoint -q "$path"; then echo "Already mounted: $path" >&2; exit 1; fi
done
# Unmount ordinary desktop mounts. Busy mounts abort; there is no forced unmount.
for disk in "$ssd" "$hdd"; do
  while IFS= read -r device; do
    while IFS= read -r target; do
      [[ -z $target ]] || umount "$target"
    done < <(findmnt -rn -S "$device" -o TARGET || true)
    if [[ $(lsblk -dnro TYPE "$device") == crypt ]]; then cryptsetup close "$device"; fi
  done < <(lsblk -nrpo NAME "$disk" | tac)
  [[ -z $(lsblk -nrpo MOUNTPOINTS "$disk" | tr -d '[:space:]') ]]
done
install -d -m 0700 /var/lib/nas
touch /var/lib/nas/provisioning-started
umask 077
head -c 64 /dev/urandom > /var/lib/nas/storage.key
head -c 48 /dev/urandom | base64 > /var/lib/nas/restic-password
for disk in "$ssd" "$hdd"; do
  wipefs --all "$disk"
  parted --script "$disk" mklabel gpt mkpart primary 1MiB 100%
done
udevadm settle
cryptsetup luksFormat --type luks2 --batch-mode --key-file /var/lib/nas/storage.key "${ssd}-part1"
cryptsetup open --allow-discards --key-file /var/lib/nas/storage.key "${ssd}-part1" nas-storage
mkfs.btrfs --label water-storage /dev/mapper/nas-storage
mkfs.ext4 -F -m 0 -L water-backup "${hdd}-part1"
install -d -m 0700 /mnt/water-nas-top
mount /dev/mapper/nas-storage /mnt/water-nas-top
btrfs subvolume create /mnt/water-nas-top/@data
btrfs subvolume create /mnt/water-nas-top/@snapshots
chmod 0755 /mnt/water-nas-top/@data
chmod 0700 /mnt/water-nas-top/@snapshots
umount /mnt/water-nas-top
install -d /srv/storage /srv/storage-snapshots /srv/backup
mount -o subvol=@data,compress=zstd,noatime /dev/mapper/nas-storage /srv/storage
mount -o subvol=@snapshots,compress=zstd,noatime /dev/mapper/nas-storage /srv/storage-snapshots
mount -o noatime "${hdd}-part1" /srv/backup
chmod 0700 /srv/backup
install -d -m 0700 -o "$primary_user" -g users /srv/storage/shared
install -d -m 0700 /srv/storage/services /srv/storage/.backup-state
head -c 4096 /dev/urandom > /srv/storage/.backup-state/restore-probe
cryptsetup luksHeaderBackup "${ssd}-part1" --header-backup-file /var/lib/nas/storage-luks-header
cat > /var/lib/nas/RECOVERY.txt <<'RECOVERY'
Keep this bundle OFF this machine, private and safe. It unlocks the 4-TB SSD
and the encrypted Restic repository on the 8-TB HDD.
Open storage: cryptsetup open --key-file storage.key /dev/disk/by-id/ata-Samsung_SSD_870_EVO_4TB_S6PJNS0W608033T-part1 nas-storage
Mount storage: mount -o subvol=@data /dev/mapper/nas-storage /mnt/storage
Mount backup: mount /dev/disk/by-id/ata-ST8000DM004-2U9188_ZR12D48Y-part1 /mnt/backup
List backups: restic -r /mnt/backup/restic --password-file restic-password snapshots
Restore: restic -r /mnt/backup/restic --password-file restic-password restore latest --target /mnt/restore
Restored data is under srv/storage-snapshots/nightly; .backup-state holds the
Immich PostgreSQL dump, global roles, original path mapping and NixOS version.
Restore databases with services STOPPED and a matching PostgreSQL/Immich version.
The LUKS header backup is emergency metadata, not a backup of the SSD's files.
RECOVERY
tar -C /var/lib/nas -czf /var/lib/nas/recovery.tar.gz storage.key storage-luks-header restic-password RECOVERY.txt
install -m 0600 -o "$primary_user" -g users /var/lib/nas/recovery.tar.gz "/home/$primary_user/water-nas-recovery.tar.gz"
echo "Recovery bundle: /home/$primary_user/water-nas-recovery.tar.gz — copy it off this machine."
# Seed the copy while services run; the stopped pass reconciles changed files.
for i in "${!sources[@]}"; do
  mkdir -p "/srv/storage/${directories[$i]}"
  rc=0
  rsync -aHAX --numeric-ids --info=progress2 "${sources[$i]}/" "/srv/storage/${directories[$i]}/" || rc=$?
  [[ $rc == 0 || $rc == 24 ]]
done
active=()
for unit in "${consumers[@]}"; do
  if systemctl is-active --quiet "$unit"; then active+=("$unit"); fi
done
resume() { if ((${#active[@]})); then systemctl start "${active[@]}"; fi; }
trap resume EXIT
if ((${#active[@]})); then
  systemctl stop "${active[@]}" || echo 'A service timed out stopping; checking that every writer has exited.'
  for unit in "${active[@]}"; do
    state=$(systemctl show --value -p ActiveState "$unit")
    [[ $state == inactive || $state == failed ]]
    [[ $(systemctl show --value -p MainPID "$unit") == 0 ]]
    group=$(systemctl show --value -p ControlGroup "$unit")
    if [[ -n $group && -e /sys/fs/cgroup$group/cgroup.events ]]; then
      grep -qx 'populated 0' "/sys/fs/cgroup$group/cgroup.events"
    fi
  done
fi
for i in "${!sources[@]}"; do
  source=${sources[$i]}
  destination=/srv/storage/${directories[$i]}
  rsync -aHAX --numeric-ids --delete "$source/" "$destination/"
  rsync -aHAXn --numeric-ids --delete --itemize-changes "$source/" "$destination/" > /var/lib/nas/copy-check
  [[ ! -s /var/lib/nas/copy-check ]] || { echo "Copy verification failed: $source" >&2; exit 1; }
done
# Preserve the old generation and source directories on the NVMe.
readlink -f /run/current-system > /var/lib/nas/previous-system
nix-store --add-root /var/lib/nas/previous-system-root --indirect --realise "$(cat /var/lib/nas/previous-system)"
nix-env --profile /nix/var/nix/profiles/system --set "$new_system"
"$new_system/bin/switch-to-configuration" switch
resume
active=()
trap - EXIT
for i in "${!sources[@]}"; do
  mountpoint -q "${sources[$i]}"
  [[ $(stat -c '%d:%i' "${sources[$i]}") == "$(stat -c '%d:%i' "/srv/storage/${directories[$i]}")" ]]
done
# Timers remain gated until this first backup and restore check succeed.
nas-backup
test -s /var/lib/nas/last-backup-success
touch /var/lib/nas/provisioning-complete
echo 'Migration and first backup complete. OS originals remain under the bind mounts.'
echo 'Set the SMB password for katara (it can be different from the login password):'
smbpasswd -a "$primary_user"
echo 'Open smb://water/Storage or smb://192.168.1.114/Storage as katara.'
