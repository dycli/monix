# Resume the verified formatted disks, before any service bind mounts are active.
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
exec 8>/run/lock/nas-provision.lock
flock -n 8
umask 077
[[ $# == 1 && -x $1/bin/switch-to-configuration ]] || { echo 'Usage: resume-water-nas /nix/store/...-nixos-system-water-...' >&2; exit 1; }
new_system=$(readlink -f "$1")
[[ $(hostname) == water ]]
[[ $(findmnt -nro UUID /) == d678129c-2832-4ae7-b376-dfddf615654f ]]
[[ -f $new_system/etc/nas/layout ]]
[[ -f /var/lib/nas/provisioning-started && ! -e /var/lib/nas/provisioning-complete ]]
[[ -s /var/lib/nas/storage.key && -s /var/lib/nas/restic-password ]]
ssd=/dev/disk/by-id/ata-Samsung_SSD_870_EVO_4TB_S6PJNS0W608033T
hdd=/dev/disk/by-id/ata-ST8000DM004-2U9188_ZR12D48Y
[[ $(lsblk -dnro SERIAL "$ssd") == S6PJNS0W608033T ]]
[[ $(lsblk -dnro SERIAL "$hdd") == ZR12D48Y ]]
[[ $(cryptsetup luksUUID "${ssd}-part1") == fb4b077e-7894-4c5f-854d-a067e82ce9df ]]
[[ $(blkid -p -s UUID -o value "${hdd}-part1") == 14e41b90-61af-4bd0-9c56-651491009a3b ]]
[[ $(blkid -p -s TYPE -o value "${hdd}-part1") == ext4 ]]
cryptsetup open --test-passphrase --key-file /var/lib/nas/storage.key "${ssd}-part1"
for path in "${sources[@]}"; do
  [[ -d $path && ! -L $path ]]
  if mountpoint -q "$path"; then echo "Already migrated: $path; refusing to recopy." >&2; exit 1; fi
  [[ $(findmnt -nro UUID -T "$path") == d678129c-2832-4ae7-b376-dfddf615654f ]]
done
for path in /srv/storage /srv/storage-snapshots; do
  mountpoint -q "$path"
  [[ $(findmnt -nro UUID -M "$path") == 5c4f9798-355a-4d8b-9801-51624ba073b4 ]]
done
[[ $(findmnt -nro FSROOT -M /srv/storage) == /@data ]]
[[ $(findmnt -nro FSROOT -M /srv/storage-snapshots) == /@snapshots ]]
modprobe ext4
if ! mountpoint -q /srv/backup; then mount -t ext4 -o noatime "${hdd}-part1" /srv/backup; fi
[[ $(findmnt -nro UUID -M /srv/backup) == 14e41b90-61af-4bd0-9c56-651491009a3b ]]
