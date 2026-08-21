pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    property bool enabled: false
    property bool settingsLoaded: false
    property real strength: 0.25
    readonly property int minimumTemperature: 2500
    readonly property int maximumTemperature: 6500
    readonly property int temperature: Math.round(maximumTemperature
        - strength * (maximumTemperature - minimumTemperature))

    property FileView settingsFile: FileView {
        path: StandardPaths.writableLocation(StandardPaths.GenericStateLocation)
            + "/kestrel/night-light-temperature"
        blockLoading: true
        blockWrites: true
        watchChanges: false

        onLoaded: root.loadTemperature(text())
        onLoadFailed: root.settingsLoaded = true
    }

    property Process statusProcess: Process {
        command: ["systemctl", "--user", "is-active", "--quiet", "hyprsunset.service"]
        onExited: exitCode => root.enabled = exitCode === 0
    }

    property Process controlProcess: Process {
        onExited: root.refresh()
    }

    property Timer applyTimer: Timer {
        interval: 250
        onTriggered: {
            if (!root.enabled || root.controlProcess.running)
                return;
            root.controlProcess.command = [
                "systemctl", "--user", "restart", "hyprsunset.service"
            ];
            root.controlProcess.running = true;
        }
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

    function loadTemperature(contents: string): void {
        const parsed = Number(String(contents || "").trim());
        if (Number.isFinite(parsed) && parsed >= minimumTemperature
                && parsed <= maximumTemperature) {
            strength = (maximumTemperature - parsed)
                / (maximumTemperature - minimumTemperature);
        }
        settingsLoaded = true;
    }

    function setStrength(value: real): void {
        strength = Math.max(0, Math.min(1, value));
        if (settingsLoaded)
            settingsFile.setText(String(temperature) + "\n");
        if (enabled)
            applyTimer.restart();
    }

    function toggle(): void {
        if (controlProcess.running)
            return;
        controlProcess.command = [
            "systemctl", "--user", enabled ? "stop" : "start", "hyprsunset.service"
        ];
        controlProcess.running = true;
    }
}
