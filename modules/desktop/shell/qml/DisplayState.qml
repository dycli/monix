pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

QtObject {
    id: root

    property var outputs: []
    property var profiles: ({})
    property var defaults: ({})
    property string mode: "single"
    property string side: "right"
    property string alignment: "center"
    property string topologyKey: ""
    property bool settingsLoaded: false
    property bool applyQueued: false

    readonly property var internalOutput: outputs.find(output => output.internal) || null
    readonly property var externalOutputs: outputs.filter(output => !output.internal)
    readonly property var externalOutput: externalOutputs.length > 0 ? externalOutputs[0] : null
    readonly property bool multipleDisplays: internalOutput !== null && externalOutput !== null
    readonly property bool busy: applyProcess.running
    readonly property string internalLabel: outputLabel(internalOutput, "Laptop display")
    readonly property string externalLabel: outputLabel(externalOutput, "External display")

    property FileView settingsFile: FileView {
        path: StandardPaths.writableLocation(StandardPaths.GenericStateLocation)
            + "/kestrel/display-settings.json"
        blockLoading: true
        blockWrites: true
        watchChanges: false

        onLoaded: root.loadSettings(text())
        onLoadFailed: {
            root.settingsLoaded = true;
            root.refresh();
        }
    }

    property Process inventoryProcess: Process {
        command: ["hyprctl", "-j", "monitors", "all"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyInventory(text)
        }
    }

    property Process applyProcess: Process {
        onExited: {
            refreshAfterApply.restart();
            if (root.applyQueued) {
                root.applyQueued = false;
                root.applyCurrent();
            }
        }
    }

    property Timer inventoryTimer: Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    property Connections hyprlandEvents: Connections {
        target: Hyprland

        function onRawEvent(event): void {
            if (/^monitor(?:added|removed)|^monitor\.(?:added|removed)/.test(event.name))
                root.refreshAfterHotplug.restart();
        }
    }

    property Timer refreshAfterHotplug: Timer {
        interval: 100
        onTriggered: root.refresh()
    }

    property Timer refreshAfterApply: Timer {
        interval: 300
        onTriggered: root.refresh()
    }

    function isInternal(name: string): bool {
        return /^(eDP|LVDS|DSI)-/.test(name || "");
    }

    function stableId(output): string {
        const serial = String(output.serial || "").trim();
        if (serial.length > 0 && serial !== "0x00000000")
            return [output.make || "", output.model || "", serial].join("|");
        return String(output.description || output.name || "unknown");
    }

    function outputLabel(output, fallback: string): string {
        if (!output)
            return fallback;
        const model = String(output.model || "").trim();
        return model.length > 0 && !/^0x[0-9A-F]+$/i.test(model) ? model : fallback;
    }

    function currentMode(output): string {
        const width = Number(output.width);
        const height = Number(output.height);
        const refresh = Number(output.refreshRate);
        if (width <= 0 || height <= 0 || refresh <= 0)
            return "preferred";
        return width + "x" + height + "@" + refresh.toFixed(3);
    }

    function loadSettings(contents: string): void {
        try {
            const parsed = JSON.parse(contents || "{}");
            profiles = parsed.profiles && typeof parsed.profiles === "object"
                ? parsed.profiles : ({});
            defaults = parsed.defaults && typeof parsed.defaults === "object"
                ? parsed.defaults : ({});
        } catch (error) {
            profiles = ({});
            defaults = ({});
        }
        settingsLoaded = true;
        refresh();
    }

    function saveSettings(): void {
        if (!settingsLoaded)
            return;
        settingsFile.setText(JSON.stringify({
            "profiles": profiles,
            "defaults": defaults
        }, null, 2));
    }

    function refresh(): void {
        if (settingsLoaded && !inventoryProcess.running)
            inventoryProcess.running = true;
    }

    function applyInventory(contents: string): void {
        let parsed;
        try {
            parsed = JSON.parse(contents || "[]");
        } catch (error) {
            return;
        }
        if (!Array.isArray(parsed) || parsed.length === 0)
            return;

        const nextOutputs = parsed.filter(output => output && output.name).map(output => ({
            "name": String(output.name),
            "description": String(output.description || ""),
            "make": String(output.make || ""),
            "model": String(output.model || ""),
            "serial": String(output.serial || ""),
            "width": Number(output.width) || 0,
            "height": Number(output.height) || 0,
            "refreshRate": Number(output.refreshRate) || 0,
            "scale": Number(output.scale) || 1,
            "x": Number(output.x) || 0,
            "y": Number(output.y) || 0,
            "vrr": Boolean(output.vrr),
            "disabled": Boolean(output.disabled),
            "mirrorOf": String(output.mirrorOf ?? "none"),
            "availableModes": Array.isArray(output.availableModes)
                ? output.availableModes : [],
            "internal": isInternal(String(output.name)),
            "stableId": stableId(output)
        })).sort((left, right) => {
            if (left.internal !== right.internal)
                return left.internal ? -1 : 1;
            return left.stableId.localeCompare(right.stableId);
        });

        let defaultsChanged = false;
        const nextDefaults = Object.assign({}, defaults);
        for (const output of nextOutputs) {
            if (output.disabled || nextDefaults[output.stableId])
                continue;
            nextDefaults[output.stableId] = {
                "mode": currentMode(output),
                "scale": output.scale,
                "vrr": output.vrr
            };
            defaultsChanged = true;
        }
        if (defaultsChanged) {
            defaults = nextDefaults;
            saveSettings();
        }

        const nextKey = nextOutputs.map(output => output.stableId).join("::");
        const topologyChanged = nextKey !== topologyKey;
        outputs = nextOutputs;
        topologyKey = nextKey;

        const active = nextOutputs.filter(output => !output.disabled);
        const mirrored = active.some(output => output.mirrorOf !== "none"
            && output.mirrorOf !== "-1");
        if (mirrored)
            mode = "mirror";
        else if (active.length > 1) {
            mode = "extend";
            inferExtendedLayout(active);
        } else if (active.length === 1)
            mode = active[0].internal ? "internal" : "external";
        else
            mode = "single";

        if (!topologyChanged)
            return;
        const profile = profiles[nextKey];
        if (profile && nextOutputs.length > 1) {
            mode = profile.mode || "extend";
            side = profile.side === "left" ? "left" : "right";
            alignment = ["top", "center", "bottom"].includes(profile.alignment)
                ? profile.alignment : "center";
            applyCurrent();
        } else if (active.length === 0 && internalOutput) {
            mode = "internal";
            applyCurrent();
        }
    }

    function inferExtendedLayout(activeOutputs): void {
        const internal = activeOutputs.find(output => output.internal);
        const external = activeOutputs.find(output => !output.internal);
        if (!internal || !external)
            return;
        side = external.x < internal.x ? "left" : "right";

        const internalHeight = internal.height / Math.max(0.1, internal.scale);
        const externalHeight = external.height / Math.max(0.1, external.scale);
        const topDistance = Math.abs(internal.y - external.y);
        const centerDistance = Math.abs((internal.y + internalHeight / 2)
            - (external.y + externalHeight / 2));
        const bottomDistance = Math.abs((internal.y + internalHeight)
            - (external.y + externalHeight));
        alignment = topDistance <= centerDistance && topDistance <= bottomDistance
            ? "top" : (bottomDistance <= centerDistance ? "bottom" : "center");
    }

    function saveProfile(): void {
        if (!topologyKey || outputs.length < 2)
            return;
        const nextProfiles = Object.assign({}, profiles);
        nextProfiles[topologyKey] = {
            "mode": mode,
            "side": side,
            "alignment": alignment
        };
        profiles = nextProfiles;
        saveSettings();
    }

    function setMode(nextMode: string): void {
        if (!multipleDisplays || !["extend", "mirror", "internal", "external"].includes(nextMode))
            return;
        mode = nextMode;
        saveProfile();
        applyCurrent();
    }

    function setSide(nextSide: string): void {
        if (nextSide !== "left" && nextSide !== "right")
            return;
        side = nextSide;
        mode = "extend";
        saveProfile();
        applyCurrent();
    }

    function setAlignment(nextAlignment: string): void {
        if (!["top", "center", "bottom"].includes(nextAlignment))
            return;
        alignment = nextAlignment;
        mode = "extend";
        saveProfile();
        applyCurrent();
    }

    function defaultFor(output): var {
        return defaults[output.stableId] || {
            "mode": "preferred",
            "scale": output.internal ? 2 : 1,
            "vrr": output.vrr
        };
    }

    function monitorRule(output, position: string, modeOverride: string,
            scaleOverride: real, mirrorTarget: string): string {
        const saved = defaultFor(output);
        const selectedMode = modeOverride || saved.mode || "preferred";
        const selectedScale = scaleOverride > 0 ? scaleOverride : (saved.scale || 1);
        let rule = output.name + "," + selectedMode + "," + position + "," + selectedScale;
        if (!mirrorTarget && saved.vrr)
            rule += ",vrr,1";
        if (output.internal) {
            const icc = Quickshell.env("KESTREL_INTERNAL_DISPLAY_ICC");
            if (icc.length > 0)
                rule += ",icc," + icc;
        }
        if (mirrorTarget)
            rule += ",mirror," + mirrorTarget;
        return rule;
    }

    function logicalSize(output): var {
        if (!output)
            return { "width": 1, "height": 1 };
        const saved = defaultFor(output);
        const modeMatch = String(saved.mode || "").match(/^(\d+)x(\d+)/);
        const width = modeMatch ? Number(modeMatch[1]) : Math.max(1, output.width);
        const height = modeMatch ? Number(modeMatch[2]) : Math.max(1, output.height);
        const scale = Number(saved.scale) || 1;
        return { "width": Math.round(width / scale), "height": Math.round(height / scale) };
    }

    function extendedPositions(): var {
        const internalSize = logicalSize(internalOutput);
        const externalSize = logicalSize(externalOutput);
        let internalX = side === "left" ? externalSize.width : 0;
        let externalX = side === "left" ? 0 : internalSize.width;
        let internalY = 0;
        let externalY = 0;
        const difference = Math.abs(internalSize.height - externalSize.height);
        if (alignment === "center") {
            if (internalSize.height < externalSize.height)
                internalY = Math.round(difference / 2);
            else
                externalY = Math.round(difference / 2);
        } else if (alignment === "bottom") {
            if (internalSize.height < externalSize.height)
                internalY = difference;
            else
                externalY = difference;
        }
        return {
            "internalX": internalX,
            "internalY": internalY,
            "externalX": externalX,
            "externalY": externalY
        };
    }

    function parsedModes(output): var {
        const modes = [];
        if (!output)
            return modes;
        for (const value of output.availableModes) {
            const match = String(value).match(/^(\d+)x(\d+)@(\d+(?:\.\d+)?)(?:Hz)?$/);
            if (match)
                modes.push({
                    "width": Number(match[1]),
                    "height": Number(match[2]),
                    "refresh": Number(match[3]),
                    "value": match[1] + "x" + match[2] + "@" + match[3]
                });
        }
        return modes;
    }

    function commonMirrorModes(): var {
        const internalModes = parsedModes(internalOutput);
        const externalModes = parsedModes(externalOutput);
        let bestInternal = null;
        let bestExternal = null;
        let bestPixels = 0;
        for (const internalMode of internalModes) {
            for (const externalMode of externalModes) {
                if (internalMode.width !== externalMode.width
                        || internalMode.height !== externalMode.height)
                    continue;
                const pixels = internalMode.width * internalMode.height;
                const refreshDifference = Math.abs(internalMode.refresh - externalMode.refresh);
                if (refreshDifference > 1 || pixels < bestPixels)
                    continue;
                if (pixels > bestPixels || !bestInternal
                        || Math.min(internalMode.refresh, externalMode.refresh)
                            > Math.min(bestInternal.refresh, bestExternal.refresh)) {
                    bestPixels = pixels;
                    bestInternal = internalMode;
                    bestExternal = externalMode;
                }
            }
        }
        return {
            "internal": bestInternal ? bestInternal.value : "preferred",
            "external": bestExternal ? bestExternal.value : "preferred"
        };
    }

    function applyCurrent(): void {
        if (!internalOutput)
            return;
        if (mode !== "internal" && externalOutputs.length === 0)
            return;
        if (applyProcess.running) {
            applyQueued = true;
            return;
        }

        const commands = [];
        if (mode === "internal") {
            commands.push("keyword monitor " + monitorRule(internalOutput, "0x0", "", 0, ""));
            for (const output of externalOutputs)
                commands.push("keyword monitor " + output.name + ",disable");
        } else if (mode === "external") {
            let first = true;
            for (const output of externalOutputs) {
                commands.push("keyword monitor " + monitorRule(output,
                    first ? "0x0" : "auto-right", "", 0, ""));
                first = false;
            }
            commands.push("keyword monitor " + internalOutput.name + ",disable");
        } else if (mode === "mirror") {
            const shared = commonMirrorModes();
            commands.push("keyword monitor " + monitorRule(internalOutput,
                "0x0", shared.internal, 1, ""));
            commands.push("keyword monitor " + monitorRule(externalOutput,
                "0x0", shared.external, 1, internalOutput.name));
            for (let index = 1; index < externalOutputs.length; index++)
                commands.push("keyword monitor " + externalOutputs[index].name + ",disable");
        } else {
            const positions = extendedPositions();
            commands.push("keyword monitor " + monitorRule(internalOutput,
                positions.internalX + "x" + positions.internalY, "", 0, ""));
            commands.push("keyword monitor " + monitorRule(externalOutput,
                positions.externalX + "x" + positions.externalY, "", 0, ""));
            for (let index = 1; index < externalOutputs.length; index++)
                commands.push("keyword monitor " + monitorRule(externalOutputs[index],
                    "auto-right", "", 0, ""));
        }

        applyProcess.command = ["hyprctl", "--batch", commands.join(" ; ")];
        applyProcess.running = true;
    }
}
