//@ pragma AppId org.kestrel.shell
//@ pragma Env QT_WAYLAND_DISABLE_WINDOWDECORATION=1

import Quickshell
import Quickshell.Io

ShellRoot {
    Bar {}

    IpcHandler {
        target: "power"

        function toggleIdleInhibit(): void {
            PowerService.idleInhibited = !PowerService.idleInhibited;
            OsdService.showIdleInhibit();
        }

        function idleInhibited(): bool {
            return PowerService.idleInhibited;
        }
    }

    IpcHandler {
        target: "osd"

        function volumeUp(): void { OsdService.volumeUp(); }
        function volumeDown(): void { OsdService.volumeDown(); }
        function toggleMute(): void { OsdService.toggleMute(); }
        function toggleMicMute(): void { OsdService.toggleMicMute(); }
        function brightnessUp(): void { OsdService.brightnessUp(); }
        function brightnessDown(): void { OsdService.brightnessDown(); }
    }

    IpcHandler {
        target: "launcher"

        function toggle(): void {
            LauncherService.toggle(OsdService.focusedScreenName);
        }
    }

    IpcHandler {
        target: "session"

        function toggle(): void {
            BarModeService.toggle("session", OsdService.focusedScreenName, false);
        }
    }

    IpcHandler {
        target: "clipboard"

        function toggle(): void {
            BarModeService.toggle("clipboard", OsdService.focusedScreenName, true);
        }
    }
}
