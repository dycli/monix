pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

QtObject {
    id: root

    property var menus: []
    property int activeHeading: -1
    property var popupItems: []

    property Process helper: Process {
        command: [Quickshell.env("KESTREL_APPMENU_HELPER")]
        stdinEnabled: true
        running: true

        stdout: SplitParser {
            onRead: data => root.applyUpdate(data)
        }

        onStarted: root.sendFocus()

        onRunningChanged: {
            if (!running)
                restartTimer.restart();
        }
    }

    property Timer restartTimer: Timer {
        interval: 1000
        onTriggered: root.helper.running = true
    }

    property Timer focusTimer: Timer {
        interval: 50
        onTriggered: root.sendFocus()
    }

    property Connections hyprlandEvents: Connections {
        target: Hyprland

        function onActiveToplevelChanged(): void {
            Hyprland.refreshToplevels();
            root.focusTimer.restart();
        }
    }

    property Connections activeToplevelUpdates: Connections {
        target: Hyprland.activeToplevel

        function onLastIpcObjectChanged(): void {
            root.sendFocus();
        }
    }

    Component.onCompleted: {
        Hyprland.refreshToplevels();
        focusTimer.start();
    }

    function applyUpdate(data: string): void {
        try {
            const update = JSON.parse(data);
            if (Array.isArray(update.menus)) {
                menus = update.menus;
                if (menus.length === 0)
                    close();
            }
            if (update.popup) {
                popupItems = Array.isArray(update.popup.items) ? update.popup.items : [];
                activeHeading = Number(update.popup.heading);
            }
        } catch (error) {
            menus = [];
            close();
        }
    }

    function sendFocus(): void {
        if (!helper.running)
            return;
        const toplevel = Hyprland.activeToplevel;
        const pid = toplevel && toplevel.lastIpcObject
            ? Number(toplevel.lastIpcObject.pid || 0) : 0;
        helper.write(JSON.stringify({ "focus": pid }) + "\n");
    }

    function open(index: int): void {
        if (!helper.running)
            return;
        if (activeHeading === index) {
            close();
            return;
        }
        helper.write(JSON.stringify({ "show": index }) + "\n");
    }

    function activate(id: int): void {
        if (helper.running)
            helper.write(JSON.stringify({ "activate": id }) + "\n");
        close();
    }

    function close(): void {
        activeHeading = -1;
        popupItems = [];
    }
}
