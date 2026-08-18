pragma Singleton

import QtQuick
import Quickshell

QtObject {
    function run(command: var): void {
        BarModeService.close();
        Quickshell.execDetached(command);
    }

    function lock(): void {
        run(["loginctl", "lock-session"]);
    }

    function suspend(): void {
        run(["systemctl", "suspend"]);
    }

    function logout(): void {
        run(["uwsm", "stop"]);
    }

    function reboot(): void {
        run(["systemctl", "reboot"]);
    }

    function powerOff(): void {
        run(["systemctl", "poweroff"]);
    }
}
