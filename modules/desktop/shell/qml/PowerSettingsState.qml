pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

QtObject {
    id: root

    property bool loaded: false
    property bool restartQueued: false
    property bool automaticProfile: false
    property string acProfile: "balanced"
    property string batteryProfile: "power-saver"
    property var policies: ({
        "default": defaultPolicy(),
        "power-saver": defaultPolicy(),
        "balanced": defaultPolicy(),
        "performance": defaultPolicy()
    })

    readonly property string currentPolicyKey: PowerService.hasBattery
        && PowerService.profilesAvailable ? PowerService.currentProfileKey : "default"
    readonly property var currentPolicy: policies[currentPolicyKey] || defaultPolicy()

    property FileView settingsFile: FileView {
        path: StandardPaths.writableLocation(StandardPaths.GenericStateLocation)
            + "/kestrel/power-settings.json"
        blockLoading: true
        blockWrites: true
        watchChanges: false

        onLoaded: root.load(text())
        onLoadFailed: {
            root.loaded = true;
            root.applyAutomaticProfile();
        }
    }

    property Process restartProcess: Process {
        onExited: {
            if (root.restartQueued) {
                root.restartQueued = false;
                root.applyTimer.restart();
            }
        }
    }

    property Timer applyTimer: Timer {
        interval: 300
        onTriggered: {
            if (root.restartProcess.running) {
                root.restartQueued = true;
                return;
            }
            root.restartProcess.command = [
                "systemctl", "--user", "restart", "hypridle.service"
            ];
            root.restartProcess.running = true;
        }
    }

    property Connections profileEvents: Connections {
        target: PowerProfiles

        function onProfileChanged(): void {
            root.applyTimer.restart();
        }
    }

    property Connections powerEvents: Connections {
        target: PowerService

        function onHasBatteryChanged(): void {
            root.applyAutomaticProfile();
        }

        function onPluggedInChanged(): void {
            root.applyAutomaticProfile();
        }
    }

    function defaultPolicy(): var {
        return {
            "lockEnabled": environmentBool("KESTREL_IDLE_LOCK_ENABLED", false),
            "lockMinutes": environmentMinutes("KESTREL_IDLE_LOCK_MINUTES", 5),
            "displayOffEnabled": environmentBool(
                "KESTREL_IDLE_DISPLAY_OFF_ENABLED", false),
            "displayOffMinutes": environmentMinutes(
                "KESTREL_IDLE_DISPLAY_OFF_MINUTES", 7),
            "suspendEnabled": true,
            "suspendMinutes": 10
        };
    }

    function environmentBool(name: string, fallback: bool): bool {
        const value = Quickshell.env(name);
        return value === "true" ? true : value === "false" ? false : fallback;
    }

    function environmentMinutes(name: string, fallback: int): int {
        const value = Quickshell.env(name);
        return value === "" ? fallback : boundedMinutes(value, fallback, 1, 60);
    }

    function boundedMinutes(value, fallback: int, minimum: int, maximum: int): int {
        const parsed = Number(value);
        return Number.isFinite(parsed)
            ? Math.max(minimum, Math.min(maximum, Math.round(parsed))) : fallback;
    }

    function cleanPolicy(value): var {
        const source = value && typeof value === "object" ? value : ({});
        const defaults = defaultPolicy();
        return {
            "lockEnabled": typeof source.lockEnabled === "boolean"
                ? source.lockEnabled : defaults.lockEnabled,
            "lockMinutes": boundedMinutes(source.lockMinutes, defaults.lockMinutes, 1, 60),
            "displayOffEnabled": typeof source.displayOffEnabled === "boolean"
                ? source.displayOffEnabled : defaults.displayOffEnabled,
            "displayOffMinutes": boundedMinutes(
                source.displayOffMinutes, defaults.displayOffMinutes, 1, 60),
            "suspendEnabled": source.suspendEnabled !== false,
            "suspendMinutes": boundedMinutes(source.suspendMinutes, 10, 5, 120)
        };
    }

    function validProfileKey(key: string): bool {
        return ["power-saver", "balanced", "performance"].includes(key);
    }

    function load(contents: string): void {
        try {
            const parsed = JSON.parse(contents || "{}");
            const stored = parsed.policies && typeof parsed.policies === "object"
                ? parsed.policies : ({});
            policies = {
                "default": cleanPolicy(stored.default),
                "power-saver": cleanPolicy(stored["power-saver"]),
                "balanced": cleanPolicy(stored.balanced),
                "performance": cleanPolicy(stored.performance)
            };
            automaticProfile = parsed.automaticProfile === true;
            acProfile = validProfileKey(parsed.acProfile) ? parsed.acProfile : "balanced";
            batteryProfile = validProfileKey(parsed.batteryProfile)
                ? parsed.batteryProfile : "power-saver";
        } catch (error) {
            // Keep defaults when the state file is incomplete.
        }
        loaded = true;
        applyAutomaticProfile();
    }

    function save(): void {
        if (!loaded)
            return;
        settingsFile.setText(JSON.stringify({
            "automaticProfile": automaticProfile,
            "acProfile": acProfile,
            "batteryProfile": batteryProfile,
            "policies": policies
        }, null, 2));
        applyTimer.restart();
    }

    function sliderValue(minutes: int, minimum: int, maximum: int): real {
        return (minutes - minimum) / Math.max(1, maximum - minimum);
    }

    function sliderMinutes(value: real, minimum: int, maximum: int): int {
        return Math.round(minimum + Math.max(0, Math.min(1, value))
            * (maximum - minimum));
    }

    function setPolicyField(field: string, value): void {
        const nextPolicies = Object.assign({}, policies);
        const nextPolicy = Object.assign({}, currentPolicy);
        nextPolicy[field] = value;
        nextPolicies[currentPolicyKey] = nextPolicy;
        policies = nextPolicies;
        save();
    }

    function togglePolicyField(field: string): void {
        setPolicyField(field, currentPolicy[field] !== true);
    }

    function setTimeout(field: string, value: real, minimum: int, maximum: int): void {
        setPolicyField(field, sliderMinutes(value, minimum, maximum));
    }

    function toggleAutomaticProfile(): void {
        automaticProfile = !automaticProfile;
        save();
        applyAutomaticProfile();
    }

    function setAutomaticProfile(source: string, key: string): void {
        if (!validProfileKey(key))
            return;
        if (source === "ac")
            acProfile = key;
        else if (source === "battery")
            batteryProfile = key;
        else
            return;
        save();
        applyAutomaticProfile();
    }

    function applyAutomaticProfile(): void {
        if (!loaded || !automaticProfile || !PowerService.hasBattery
                || !PowerService.profilesAvailable)
            return;
        PowerService.setProfileByKey(PowerService.pluggedIn ? acProfile : batteryProfile);
    }
}
