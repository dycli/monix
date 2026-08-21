pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell.Io

QtObject {
    id: root

    property int repeatRate: 100
    property int repeatDelay: 200
    property real pointerSpeed: 0
    property string accelerationProfile: "adaptive"
    property real mouseScrollFactor: 1
    property real touchpadScrollFactor: 1
    property string lastError: ""
    property string applyOutput: ""
    property string applyError: ""

    property bool loaded: false
    property bool applyQueued: false

    property FileView settingsFile: FileView {
        path: StandardPaths.writableLocation(StandardPaths.GenericStateLocation)
            + "/kestrel/input-settings.json"
        blockLoading: true
        blockWrites: true
        watchChanges: false

        onLoaded: root.loadSettings(text())
        onLoadFailed: root.loaded = true
    }

    property Process applyProcess: Process {
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyOutput = text.trim()
        }
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyError = text.trim()
        }
        onExited: exitCode => {
            const response = root.applyError || root.applyOutput;
            if (exitCode !== 0 || /error|invalid|failed/i.test(response))
                root.lastError = response || "Hyprland rejected the input change";
            if (root.applyQueued) {
                root.applyQueued = false;
                root.applyNow();
            }
        }
    }

    property Timer applyTimer: Timer {
        interval: 75
        onTriggered: root.applyNow()
    }

    property Timer saveTimer: Timer {
        interval: 250
        onTriggered: root.saveSettings()
    }

    function boundedNumber(value, fallback: real, minimum: real, maximum: real): real {
        const parsed = Number(value);
        return Number.isFinite(parsed)
            ? Math.max(minimum, Math.min(maximum, parsed)) : fallback;
    }

    function loadSettings(contents: string): void {
        try {
            const parsed = JSON.parse(contents || "{}");
            repeatRate = Math.round(boundedNumber(parsed.repeatRate, repeatRate, 1, 200));
            repeatDelay = Math.round(boundedNumber(parsed.repeatDelay, repeatDelay, 50, 2000));
            pointerSpeed = boundedNumber(parsed.pointerSpeed, pointerSpeed, -1, 1);
            accelerationProfile = parsed.accelerationProfile === "flat"
                ? "flat" : "adaptive";
            mouseScrollFactor = boundedNumber(parsed.mouseScrollFactor,
                mouseScrollFactor, 0.1, 5);
            touchpadScrollFactor = boundedNumber(parsed.touchpadScrollFactor,
                touchpadScrollFactor, 0.1, 5);
        } catch (error) {
        }
        loaded = true;
        applyTimer.start();
    }

    function saveSettings(): void {
        if (!loaded)
            return;
        settingsFile.setText(JSON.stringify({
            "repeatRate": repeatRate,
            "repeatDelay": repeatDelay,
            "pointerSpeed": pointerSpeed,
            "accelerationProfile": accelerationProfile,
            "mouseScrollFactor": mouseScrollFactor,
            "touchpadScrollFactor": touchpadScrollFactor
        }, null, 2));
    }

    function changed(): void {
        if (!loaded)
            return;
        saveTimer.restart();
        if (!applyTimer.running)
            applyTimer.start();
    }

    function setRepeatRate(value: int): void {
        repeatRate = Math.max(1, Math.min(200, value));
        changed();
    }

    function setRepeatDelay(value: int): void {
        repeatDelay = Math.max(50, Math.min(2000, value));
        changed();
    }

    function setPointerSpeed(value: real): void {
        pointerSpeed = Math.max(-1, Math.min(1, value));
        changed();
    }

    function setAccelerationProfile(value: string): void {
        accelerationProfile = value === "flat" ? "flat" : "adaptive";
        changed();
    }

    function setMouseScrollFactor(value: real): void {
        mouseScrollFactor = Math.max(0.1, Math.min(5, value));
        changed();
    }

    function setTouchpadScrollFactor(value: real): void {
        touchpadScrollFactor = Math.max(0.1, Math.min(5, value));
        changed();
    }

    function applyNow(): void {
        if (!loaded)
            return;
        if (applyProcess.running) {
            applyQueued = true;
            return;
        }

        lastError = "";
        applyOutput = "";
        applyError = "";
        const command = "hl.config({ input = { repeat_rate = " + repeatRate
            + ", repeat_delay = " + repeatDelay
            + ", sensitivity = " + pointerSpeed.toFixed(3)
            + ", accel_profile = " + JSON.stringify(accelerationProfile)
            + ", scroll_factor = " + mouseScrollFactor.toFixed(3)
            + ", touchpad = { scroll_factor = "
            + touchpadScrollFactor.toFixed(3) + " } } })";
        applyProcess.command = ["hyprctl", "eval", command];
        applyProcess.running = true;
    }
}
