pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    property var entries: []

    property Process listProcess: Process {
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyList(text)
        }
    }

    property Process decodeProcess: Process {
        onExited: exitCode => {
            if (exitCode === 0)
                root.pasteTimer.restart();
        }
    }

    property Process deleteProcess: Process {
        onExited: root.refresh()
    }

    property Timer pasteTimer: Timer {
        interval: 80
        onTriggered: Quickshell.execDetached(["wtype", "-M", "ctrl", "v", "-m", "ctrl"])
    }

    function refresh(): void {
        if (!listProcess.running)
            listProcess.running = true;
    }

    function applyList(output: string): void {
        const nextEntries = [];
        const lines = output.split("\n");
        for (const line of lines) {
            const separator = line.indexOf("\t");
            if (separator <= 0)
                continue;
            const id = line.slice(0, separator).trim();
            if (!/^\d+$/.test(id))
                continue;
            const preview = line.slice(separator + 1).replace(/\s+/g, " ").trim();
            nextEntries.push({ "entryId": id, "preview": preview || "Clipboard item" });
        }
        entries = nextEntries;
    }

    function filtered(query: string): var {
        const needle = query.trim().toLowerCase();
        const matches = [];
        for (const entry of entries) {
            if (needle.length === 0 || entry.preview.toLowerCase().includes(needle))
                matches.push({ "entryId": entry.entryId, "preview": entry.preview });
            if (matches.length >= 4)
                break;
        }
        return matches;
    }

    function paste(entryId: string): void {
        if (!/^\d+$/.test(entryId) || decodeProcess.running)
            return;
        BarModeService.close();
        decodeProcess.command = [
            "sh", "-c",
            "printf '%s' \"$1\" | cliphist decode | wl-copy",
            "kestrel-clipboard", entryId
        ];
        decodeProcess.running = true;
    }

    function remove(entryId: string): void {
        if (!/^\d+$/.test(entryId) || deleteProcess.running)
            return;
        deleteProcess.command = ["cliphist", "delete-query", entryId];
        deleteProcess.running = true;
    }
}
