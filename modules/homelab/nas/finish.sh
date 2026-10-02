chmod 0700 /srv/backup
install -d -m 0700 -o "$primary_user" -g users /srv/storage/shared
install -d -m 0700 /srv/storage/services /srv/storage/.backup-state
head -c 4096 /dev/urandom > /srv/storage/.backup-state/restore-probe
if [[ ! -f /var/lib/nas/storage-luks-header ]]; then
  cryptsetup luksHeaderBackup "${ssd}-part1" --header-backup-file /var/lib/nas/storage-luks-header
fi
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
echo 'Open smb://water/storage or smb://192.168.1.114/storage as katara.'
