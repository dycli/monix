pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    property bool available: false
    property string backend: "backlight"
    property string device: ""
    property real level: 0
    property int maximum: 100
    property real pendingLevel: 0
    property bool setQueued: false
    property int refreshFailures: 0

    readonly property string icon: !available
        ? "󰛩"
        : (level < 0.34 ? "󰃞" : (level < 0.67 ? "󰃟" : "󰃠"))

    property Process refreshProcess: Process {
        command: root.backend === "ddc"
            ? ["ddcutil", "getvcp", "10", "--brief"]
            : ["brightnessctl", "-m", "-c", "backlight"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyRefresh(text)
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
        interval: root.backend === "ddc"
            ? 30000 : (root.refreshFailures >= 3 ? 60000 : 3000)
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!root.refreshProcess.running)
                root.refreshProcess.running = true;
        }
    }

    property Timer ddcFallbackTimer: Timer {
        interval: 0
        onTriggered: {
            if (!root.refreshProcess.running)
                root.refreshProcess.running = true;
        }
    }

    function applyRefresh(output: string): void {
        if (backend === "ddc")
            applyDdcState(output);
        else
            applyBacklightState(output);
    }

    function applyBacklightState(output: string): void {
        const line = output.split("\n").find(value => value.trim().length > 0) || "";
        const fields = line.split(",");
        const percentField = fields.find(value => String(value).trim().endsWith("%")) || "";
        const percent = Number(String(percentField).trim().replace("%", ""));
        if (fields.length < 2 || !Number.isFinite(percent)) {
            available = false;
            device = "";
            backend = "ddc";
            refreshFailures = 0;
            ddcFallbackTimer.restart();
            return;
        }
        refreshFailures = 0;
        available = true;
        device = fields[0].trim();
        maximum = 100;
        if (!setProcess.running && !setQueued)
            level = Math.max(0, Math.min(1, percent / 100));
    }

    function applyDdcState(output: string): void {
        const match = output.match(/VCP\s+10\s+C\s+(\d+)\s+(\d+)/);
        const current = match ? Number(match[1]) : NaN;
        const detectedMaximum = match ? Number(match[2]) : NaN;
        if (!Number.isFinite(current) || !Number.isFinite(detectedMaximum)
                || detectedMaximum <= 0) {
            available = false;
            device = "";
            refreshFailures += 1;
            return;
        }
        refreshFailures = 0;
        available = true;
        device = "ddc:1";
        maximum = detectedMaximum;
        if (!setProcess.running && !setQueued)
            level = Math.max(0, Math.min(1, current / detectedMaximum));
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
        setProcess.command = backend === "ddc"
            ? ["ddcutil", "setvcp", "10", String(Math.max(1,
                Math.round(pendingLevel * maximum))), "--noverify"]
            : ["brightnessctl", "-q", "-d", device, "set",
                Math.round(pendingLevel * 100) + "%"];
        setProcess.running = true;
    }
}
