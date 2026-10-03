pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell.Hyprland
import Quickshell.Io

QtObject {
    id: root

    property int repeatRate: 100
    property int repeatDelay: 200
    property real pointerSpeed: 0
    property string accelerationProfile: "adaptive"
    property real mouseScrollFactor: 1
    property real touchpadScrollFactor: 1
    // Pointer settings keyed by Hyprland device name. A device without an
    // entry follows the global values above.
    property var deviceOverrides: ({})
    property var connectedDevices: []
    property string selectedDevice: ""
    readonly property var knownDevices: connectedDevices.concat(
        Object.keys(deviceOverrides).filter(name => !connectedDevices.includes(name)).sort())
    readonly property var selectedOverride: deviceOverrides[selectedDevice] ?? null
    readonly property real selectedPointerSpeed: selectedSetting("pointerSpeed")
    readonly property string selectedAccelerationProfile: selectedSetting("accelerationProfile")
    readonly property real selectedScrollFactor: selectedSetting("scrollFactor")
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

    property Process devicesProcess: Process {
        command: ["hyprctl", "devices", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    root.connectedDevices = (JSON.parse(text).mice || [])
                        .map(mouse => mouse.name).filter(name => name);
                    if (!root.knownDevices.includes(root.selectedDevice))
                        root.selectedDevice = "";
                } catch (error) {
                }
            }
        }
    }

    // Hyprland cannot unset a single device field, so dropping an override
    // reloads the config; configreloaded then reapplies everything else.
    property Process reloadProcess: Process {
        command: ["hyprctl", "reload"]
    }

    property Timer applyTimer: Timer {
        interval: 75
        onTriggered: root.applyNow()
    }

    property Timer saveTimer: Timer {
        interval: 250
        onTriggered: root.saveSettings()
    }

    property Connections hyprlandEvents: Connections {
        target: Hyprland

        function onRawEvent(event): void {
            if (event.name === "configreloaded")
                root.reapplyAfterConfigReload.restart();
        }
    }

    property Timer reapplyAfterConfigReload: Timer {
        interval: 250
        onTriggered: root.applyNow()
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
                mouseScrollFactor, 0.1, 2);
            touchpadScrollFactor = boundedNumber(parsed.touchpadScrollFactor,
                touchpadScrollFactor, 0.1, 2);
            const overrides = {};
            for (const [name, device] of Object.entries(parsed.devices || {}))
                overrides[name] = {
                    "pointerSpeed": boundedNumber(device.pointerSpeed, pointerSpeed, -1, 1),
                    "accelerationProfile": device.accelerationProfile === "flat"
                        ? "flat" : "adaptive",
                    "scrollFactor": boundedNumber(device.scrollFactor,
                        defaultScrollFactor(name), 0.1, 5)
                };
            deviceOverrides = overrides;
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
            "touchpadScrollFactor": touchpadScrollFactor,
            "devices": deviceOverrides
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

    function refreshDevices(): void {
        if (!devicesProcess.running)
            devicesProcess.running = true;
    }

    function selectDevice(name: string): void {
        selectedDevice = name;
    }

    // Hyprland applies a device scroll_factor to wheel and finger scrolling
    // alike, so a touchpad starts from the touchpad factor.
    function defaultScrollFactor(name: string): real {
        return /touchpad|trackpad/i.test(name) ? touchpadScrollFactor : mouseScrollFactor;
    }

    function selectedSetting(key: string) {
        if (selectedOverride)
            return selectedOverride[key];
        if (key === "scrollFactor")
            return selectedDevice ? defaultScrollFactor(selectedDevice) : mouseScrollFactor;
        return key === "pointerSpeed" ? pointerSpeed : accelerationProfile;
    }

    function setDeviceSetting(key: string, value): void {
        const overrides = Object.assign({}, deviceOverrides);
        overrides[selectedDevice] = Object.assign({
            "pointerSpeed": pointerSpeed,
            "accelerationProfile": accelerationProfile,
            "scrollFactor": defaultScrollFactor(selectedDevice)
        }, overrides[selectedDevice], { [key]: value });
        deviceOverrides = overrides;
        changed();
    }

    function resetDevice(name: string): void {
        if (!deviceOverrides[name])
            return;
        const overrides = Object.assign({}, deviceOverrides);
        delete overrides[name];
        deviceOverrides = overrides;
        saveTimer.restart();
        reloadProcess.running = true;
    }

    function setPointerSpeed(value: real): void {
        const bounded = Math.max(-1, Math.min(1, value));
        if (selectedDevice) {
            setDeviceSetting("pointerSpeed", bounded);
            return;
        }
        pointerSpeed = bounded;
        changed();
    }

    function setAccelerationProfile(value: string): void {
        const profile = value === "flat" ? "flat" : "adaptive";
        if (selectedDevice) {
            setDeviceSetting("accelerationProfile", profile);
            return;
        }
        accelerationProfile = profile;
        changed();
    }

    function setScrollFactor(value: real): void {
        const bounded = Math.max(0.1, Math.min(5, value));
        if (selectedDevice)
            setDeviceSetting("scrollFactor", bounded);
        else
            setMouseScrollFactor(bounded);
    }

    function setMouseScrollFactor(value: real): void {
        // Hyprland rejects global scroll factors above 2; device ones go higher.
        mouseScrollFactor = Math.max(0.1, Math.min(2, value));
        changed();
    }

    function setTouchpadScrollFactor(value: real): void {
        touchpadScrollFactor = Math.max(0.1, Math.min(2, value));
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
            + touchpadScrollFactor.toFixed(3) + " } } })"
            + Object.entries(deviceOverrides).map(([name, device]) =>
                " hl.device({ name = " + JSON.stringify(name)
                + ", sensitivity = " + device.pointerSpeed.toFixed(3)
                + ", accel_profile = " + JSON.stringify(device.accelerationProfile)
                + ", scroll_factor = " + device.scrollFactor.toFixed(3) + " })").join("");
        applyProcess.command = ["hyprctl", "eval", command];
        applyProcess.running = true;
    }
}
