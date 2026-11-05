#!/usr/bin/env bash
# The terminal under the keyboard, the placeholder and the model line, and a
# thread holding still while scrolled up mid-reply, on the emulator against
# proof_host.py. Kept in monix, with the ship's proofs; copy this directory to
# android/terminal-proof in a Libri checkout and run it inside
# `nix develop .#android-emulator` from the repository root, on boat:
# remote_run --include android/terminal-proof.
# PHASES picks from "pickers terminal follow" (default all); ONLY_AFTER=1 skips
# the comparison against baseline/Follow.kt, the build before the follow fix.
# Shots in android/terminal-proof/shots.
set -u
cd "$(dirname "$0")/.."
gradle --no-daemon -q assembleDebug || exit 1
export ANDROID_USER_HOME=~/.android ANDROID_AVD_HOME=~/.android/avd
out=terminal-proof/shots; mkdir -p "$ANDROID_AVD_HOME" $out
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$(dirname "$(ls -d "$ANDROID_HOME"/cmdline-tools/*/bin/avdmanager | head -1)"):$PATH"
echo both >/tmp/usage-fixture
python3 terminal-proof/proof_host.py 8973 >terminal-proof/host.log 2>&1 &
image=$(ls -d "$ANDROID_HOME"/system-images/*/*/x86_64 | head -1)
package=$(echo "$image" | sed "s#$ANDROID_HOME/##; s#/#;#g")
echo no | avdmanager create avd --force -n boat -k "$package" -d pixel_6 >/dev/null 2>&1
sed -i "s/^hw.keyboard=.*//" "$ANDROID_AVD_HOME/boat.avd/config.ini"; echo hw.keyboard=no >>"$ANDROID_AVD_HOME/boat.avd/config.ini"
emulator -avd boat -partition-size 4096 -no-window -no-audio -no-boot-anim -no-snapshot -accel on -gpu swiftshader_indirect >terminal-proof/emulator.log 2>&1 &
adb wait-for-device
for _ in $(seq 1 120); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 3; done
adb install -r app/build/outputs/apk/debug/app-debug.apk 2>&1 | tail -1
# The soft keyboard comes up even where the emulator reports a hardware one.
adb shell settings put secure show_ime_with_hard_keyboard 1
app=is.libri
adb shell am start -n $app/su.libri.MainActivity >/dev/null; sleep 5; adb shell am force-stop $app
printf '%s\n' "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" '<map><string name="address">http://10.0.2.2:8973</string></map>' |
  adb shell "run-as $app sh -c 'mkdir -p shared_prefs && cat > shared_prefs/libri.xml'"
dump() { for _ in 1 2 3; do adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb exec-out cat /sdcard/ui.xml && return; sleep 1; done; }
shot() { sleep 2; adb exec-out screencap -p >"$out/$1.png"; }
tap() {
  b=$(dump | grep -o "<node[^>]*\(text\|content-desc\)=\"$1\"[^>]*>" | head -1 | grep -o 'bounds="[^"]*"' | grep -oE '[0-9]+' | paste -sd' ')
  [ -n "$b" ] || { echo "no node: $1"; return 1; }
  read -r l t r bo <<<"$b"; adb shell input tap $(((l + r) / 2)) $(((t + bo) / 2)); sleep 2
}
start() { adb shell am force-stop $app; adb shell am start -n $app/su.libri.MainActivity >/dev/null; sleep 10; }
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
phase() { case " ${PHASES:-pickers terminal follow} " in *" $1 "*) return 0;; esac; return 1; }
phase pickers && for theme in no yes; do
  adb shell cmd uimode night $theme >/dev/null
  start; shot "chat-$theme"
  check "placeholder says Libri ($theme)" 'dump | grep -q "Message Libri"'
  check "model line reads Opus 5.5 / Default ($theme)" 'dump | grep -q "text=\"Opus 5.5\"" && dump | grep -q "text=\"Default\""'
  tap "Default" && shot "effort-menu-$theme"; tap "High"; sleep 2
  check "effort picked: High" 'dump | grep -q "text=\"High\""'
  tap "Opus 5.5" && shot "model-menu-$theme"; adb shell input keyevent 4; sleep 1
  tap "Message Libri"; sleep 2; shot "chat-keyboard-$theme"; adb shell input keyevent 4; sleep 1
  tap "Temp"; sleep 2; shot "temp-$theme"
  check "Temp placeholder says Libri ($theme)" 'dump | grep -q "Message Libri"'
  tap "Work"; sleep 2; tap "Research the options for the garden"; sleep 3; shot "worker-$theme"
done
adb shell cmd uimode night yes >/dev/null
probe='JSON.stringify({iw: innerWidth, ih: innerHeight, dpr: devicePixelRatio, vv: [visualViewport.width, visualViewport.height, visualViewport.scale], doc: [document.documentElement.clientWidth, document.documentElement.clientHeight], screen: [document.getElementById("screen").clientWidth, document.getElementById("screen").clientHeight], canvas: [document.querySelector("canvas").style.width, document.querySelector("canvas").style.height], fonts: document.fonts && document.fonts.status})'
if phase terminal; then
  start
  tap "Terminal"; sleep 8; shot terminal-keyboard
  adb shell dumpsys input_method | grep -m1 -E "mInputShown"
  echo "page, keyboard up: $(python3 terminal-proof/cdp.py "$probe")"
  tap "Hide the keyboard"; sleep 3; shot terminal-no-keyboard
  echo "page, keyboard down: $(python3 terminal-proof/cdp.py "$probe")"
  echo "after libri.fit(): $(python3 terminal-proof/cdp.py "libri.fit(), $probe")"
  grep TERMINAL terminal-proof/host.log
  check "terminal: the host was told a phone-sized grid" 'grep TERMINAL terminal-proof/host.log | grep -vq "\"cols\":80,"'
fi
# Whether the screen's rows 300-1200 are the same in two raw screencaps.
still() {
  python3 -c "
import struct, sys
a, b = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read()
w = struct.unpack('<I', a[:4])[0]
head = 16 if (len(a) - 16) % (w * 4) == 0 else 12
row = w * 4
print('yes' if a[head + 300 * row:head + 1200 * row] == b[head + 300 * row:head + 1200 * row] else 'no')" "$1" "$2"
}
streaming() { dump | grep -q 'content-desc="Stop'; }
# A reply streams with a job under it; the person scrolls up. What they look
# at must stay where it is while the reply grows: the pair is taken 4 s apart,
# both while Stop shows.
pair() {
  adb logcat -c
  adb exec-out screencap >/tmp/still-a.raw; shot "follow-$1-a"; streaming && was=yes || was=no; sleep 4
  adb exec-out screencap >/tmp/still-b.raw; shot "follow-$1-b"; streaming && now=yes || now=no
  adb logcat -d -s Follow:D >"terminal-proof/follow-$1.log"
  same=$(still /tmp/still-a.raw /tmp/still-b.raw)
  echo "follow $1: streaming at a $was, at b $now; rows 300-1200 unchanged: $same"
  check "follow $1: stays put while streaming" '[ $was = yes ] && [ $now = yes ] && [ $same = yes ]'
}
send_stream() {
  start
  tap "Message Libri"; adb shell input text "stream%sjobs"; sleep 1; adb shell input keyevent 4; sleep 1
  tap "Send"
}
follow() {
  # An older message in view.
  send_stream; sleep 13
  adb shell input swipe 540 900 540 1500 400; sleep 1.5
  pair "$1-older"
  # The reply fills the screen and is read from its start.
  send_stream; sleep 24
  adb shell input swipe 540 1000 540 1300 400; sleep 1.5
  pair "$1-reply"
  # Back at the foot it follows again: the newest words stay on screen.
  adb shell input swipe 540 1500 540 300 200; adb shell input swipe 540 1500 540 300 200; sleep 3
  shot "follow-$1-foot"
}
if phase follow; then
follow after
[ -n "${ONLY_AFTER:-}" ] || {
# The same on the build before this branch, for comparison: expected to move.
cp terminal-proof/baseline/Follow.kt app/src/main/java/su/libri/Follow.kt
gradle --no-daemon -q assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk 2>&1 | tail -1
follow before
echo "(follow before is expected to FAIL: it is the unfixed build)"
}
fi
echo "$fails failed"
