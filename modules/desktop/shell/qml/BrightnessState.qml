pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    property bool available: false
    property string device: ""
    property real level: 0
    property real pendingLevel: 0
    property bool setQueued: false

    readonly property string icon: !available
        ? "󰛩"
        : (level < 0.34 ? "󰃞" : (level < 0.67 ? "󰃟" : "󰃠"))

    property Process refreshProcess: Process {
        command: ["brightnessctl", "-m", "-c", "backlight"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyState(text)
        }
    }

    property Process setProcess: Process {
        onRunningChanged: {
            if (running || !root.setQueued)
                return;
            root.setQueued = false;
            root.applyPendingLevel();
        }
    }

    property Timer refreshTimer: Timer {
        interval: 3000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!root.refreshProcess.running)
                root.refreshProcess.running = true;
        }
    }

    function applyState(output: string): void {
        const line = output.split("\n").find(value => value.trim().length > 0) || "";
        const fields = line.split(",");
        const percentField = fields.find(value => String(value).trim().endsWith("%")) || "";
        const percent = Number(String(percentField).trim().replace("%", ""));
        if (fields.length < 2 || !Number.isFinite(percent)) {
            available = false;
            device = "";
            return;
        }
        available = true;
        device = fields[0].trim();
        if (!setProcess.running && !setQueued)
            level = Math.max(0, Math.min(1, percent / 100));
    }

    function setLevel(value: real): void {
        if (!available)
            return;
        pendingLevel = Math.max(0.01, Math.min(1, value));
        level = pendingLevel;
        if (setProcess.running)
            setQueued = true;
        else
            applyPendingLevel();
    }

    function applyPendingLevel(): void {
        if (!available || device.length === 0)
            return;
        if (setProcess.running) {
            setQueued = true;
            return;
        }
        setProcess.command = ["brightnessctl", "-q", "-d", device, "set", Math.round(pendingLevel * 100) + "%"];
        setProcess.running = true;
    }
}
