//@ pragma AppId org.kestrel.shell
//@ pragma Env QT_WAYLAND_DISABLE_WINDOWDECORATION=1
//@ pragma UseQApplication

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    Component.onCompleted: {
        DisplayState.refresh();
        InputState.applyNow();
        PowerSettingsState.applyAutomaticProfile();
    }

    Bar {}

    IpcHandler {
        target: "power"

        function toggleIdleInhibit(): void {
            PowerService.idleInhibited = !PowerService.idleInhibited;
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
            SettingsPanelService.close();
            ClipboardPanelService.close();
            ClockPanelService.close();
            LauncherService.toggle(OsdService.focusedScreenName);
        }
    }

    IpcHandler {
        target: "session"

        function toggle(): void {
            SettingsPanelService.close();
            ClipboardPanelService.close();
            ClockPanelService.close();
            BarModeService.toggle("session", OsdService.focusedScreenName, true);
        }
    }

    IpcHandler {
        target: "clipboard"

        function toggle(): void {
            BarModeService.close();
            ClockPanelService.close();
            SettingsPanelService.close();
            ClipboardPanelService.toggle(OsdService.focusedScreenName);
        }
    }
}
