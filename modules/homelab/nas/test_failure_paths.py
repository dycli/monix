import os, pathlib, subprocess, tempfile
# Replace privileged paths and commands only in the isolated test fixture.
# Neither the installed scripts nor any real device/service is invoked here.
repo=pathlib.Path(__file__).parent
with tempfile.TemporaryDirectory(prefix='nas-tests-') as td:
    root=pathlib.Path(td)
    body=(repo/'backup.sh').read_text().replace('[[ $EUID == 0 ]]', 'true')
    for original, target in [('/var/cache/restic-nas',f'{td}/cache'),('/run/lock/nas-backup.lock',f'{td}/lock'),('/srv/storage-snapshots',f'{td}/snapshots'),('/srv/storage',f'{td}/storage'),('/srv/backup',f'{td}/backup'),('/etc/nas/layout',f'{td}/layout'),('/var/lib/nas',f'{td}/state')]:
        body=body.replace(original,target)
    prefix=r'''
set -euo pipefail
sources=(); directories=(); immich_database=immich
mountpoint() { [[ ${CASE} != missing-disk ]]; }
findmnt() { if [[ "$*" == *SOURCE* ]]; then echo /dev/fake-backup; else echo filesystem-id; fi; }
readlink() { if [[ "$*" == *ST8000* ]]; then echo /dev/fake-backup; else echo /nix/store/test-system; fi; }
blkid() { echo filesystem-id; }
systemctl() {
  echo "$*" >> "$LOG"
  case "$1" in
    is-active) [[ ${CASE} != inactive ]];;
    *) return 0;;
  esac
}
runuser() { [[ ${CASE} != dump-failure ]] || return 1; echo dump; }
btrfs() {
  [[ ${CASE} != snapshot-failure || "$*" != *snapshot* ]] || return 1
  if [[ $1 == subvolume && $2 == snapshot ]]; then mkdir -p "$5"; cp -a "$4/." "$5/"; fi
}
restic() {
  echo "restic $*" >> "$LOG"
  [[ ${CASE} != restic-failure ]] || return 1
  if [[ $1 == dump ]]; then cat "$3"; fi
}
pg_restore() { return 0; }
'''
    script=root/'backup-test.sh'; script.write_text(prefix+body)
    for case in ['missing-disk','dump-failure','snapshot-failure','restic-failure','inactive','success']:
        for name in ['storage/.backup-state','snapshots','backup','state']:(root/name).mkdir(parents=True,exist_ok=True)
        (root/'storage/.backup-state/restore-probe').write_text('restore-test')
        (root/'layout').write_text('test layout')
        log=root/'calls';log.write_text('')
        result=subprocess.run(['bash',str(script)],env={**os.environ,'CASE':case,'LOG':str(log)},capture_output=True,text=True)
        calls=log.read_text()
        success=case in ['inactive','success']
        assert (result.returncode==0)==success,(case,result.stderr,calls)
        assert ('stop immich-server.service' in calls)==(case not in ['missing-disk','inactive']), (case,calls)
        assert ('start immich-server.service' in calls)==(case not in ['missing-disk','inactive']), (case,calls)
        assert not any(x in calls for x in ['frigate.service','jellyfin.service']),calls
        assert (root/'state/last-backup-success').exists()==success,(case,calls)
        if success:(root/'state/last-backup-success').unlink()
        print('PASS',case)
print('All backup failure-path tests passed (mocked devices and service manager).')
with tempfile.TemporaryDirectory(prefix='nas-preflight-') as td:
    root=pathlib.Path(td)
    body=(repo/'prepare.sh').read_text().replace('[[ $EUID == 0 ]]', 'true')
    body=body.replace('/var/lib/nas',f'{td}/state').replace('/run/lock/nas-provision.lock',f'{td}/lock').replace('/srv/',f'{td}/srv/')
    system=root/'system'; (system/'bin').mkdir(parents=True);(system/'etc/nas').mkdir(parents=True)
    (system/'bin/switch-to-configuration').write_text('#!/bin/sh\nexit 99\n');(system/'bin/switch-to-configuration').chmod(0o755)
    (system/'etc/nas/layout').write_text('test')
    (root/'source').mkdir();(root/'state').mkdir()
    prefix=r'''
set -euo pipefail
sources=("$FIXTURE/source"); directories=(media); consumers=(); primary_user=test
hostname() { if [[ $CASE == wrong-host ]]; then echo other; else echo water; fi; }
findmnt() {
  if [[ $CASE == wrong-os || ( $CASE == wrong-source && "$*" == *-T* ) ]]; then
    echo wrong-uuid
  else echo d678129c-2832-4ae7-b376-dfddf615654f; fi
}
lsblk() {
  if [[ "$*" == *SERIAL* ]]; then
    if [[ $CASE == wrong-serial ]]; then echo WRONG;
    elif [[ "$*" == *Samsung* ]]; then echo S6PJNS0W608033T;
    else echo ZR12D48Y; fi
  elif [[ "$*" == *SIZE* ]]; then
    if [[ $CASE == wrong-size ]]; then echo 2000000000000;
    elif [[ "$*" == *Samsung* ]]; then echo 4000787030016;
    else echo 8001563222016; fi
  else echo UNEXPECTED-PREFLIGHT-PASS >> "$LOG"; return 99; fi
}
mountpoint() { [[ ( $CASE == mounted-source && "$*" == *source* ) || ( $CASE == mounted-nas && "$*" == *srv* ) ]]; }
wipefs() { echo DESTRUCTIVE >> "$LOG"; return 99; }
parted() { echo DESTRUCTIVE >> "$LOG"; return 99; }
cryptsetup() { echo DESTRUCTIVE >> "$LOG"; return 99; }
umount() { echo MUTATION >> "$LOG"; return 99; }
'''
    script=root/'prepare-test.sh';script.write_text(prefix+body)
    for case in ['wrong-host','wrong-os','wrong-serial','wrong-size','already-started','existing-key','wrong-source','mounted-source','mounted-nas']:
        for name in ['provisioning-started','storage.key']:
            (root/'state'/name).unlink(missing_ok=True)
        if case=='already-started':(root/'state/provisioning-started').touch()
        if case=='existing-key':(root/'state/storage.key').touch()
        log=root/'calls';log.write_text('')
        result=subprocess.run(['bash',str(script),str(system)],env={**os.environ,'FIXTURE':td,'CASE':case,'LOG':str(log)},capture_output=True,text=True)
        assert result.returncode!=0,(case,result.stdout,result.stderr)
        assert log.read_text()=='',(case,log.read_text())
        print('PASS preflight',case)
print('All provisioning guards rejected unsafe fixtures before any disk operation.')
