pragma Singleton

import QtQuick

QtObject {
    property string screenName: ""
    property string section: "network"

    function toggle(targetScreen: string): void {
        if (screenName === targetScreen) {
            close();
        } else {
            screenName = targetScreen;
        }
    }

    function openSection(targetScreen: string, targetSection: string): void {
        section = targetSection;
        screenName = targetScreen;
    }

    function openDisplay(targetScreen: string): void {
        openSection(targetScreen, "display");
    }

    function close(): void {
        screenName = "";
    }

    function isOpen(targetScreen: string): bool {
        return screenName === targetScreen;
    }
}
