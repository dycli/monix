pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    property bool enabled: false

    property Process statusProcess: Process {
        command: ["systemctl", "--user", "is-active", "--quiet", "hyprsunset.service"]
        onExited: exitCode => root.enabled = exitCode === 0
    }

    property Process toggleProcess: Process {
        onExited: root.refresh()
    }

    property Timer refreshTimer: Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()

    function refresh(): void {
        if (!statusProcess.running)
            statusProcess.running = true;
    }

    function toggle(): void {
        if (toggleProcess.running)
            return;
        toggleProcess.command = [
            "systemctl", "--user", enabled ? "stop" : "start", "hyprsunset.service"
        ];
        toggleProcess.running = true;
    }
}
