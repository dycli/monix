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
modprobe ext4
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
mount -t ext4 -o noatime "${hdd}-part1" /srv/backup
