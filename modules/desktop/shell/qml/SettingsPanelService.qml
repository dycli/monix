pragma Singleton

import QtQuick

QtObject {
    property string screenName: ""
    property bool displayExpanded: false

    function toggle(targetScreen: string): void {
        if (screenName === targetScreen) {
            close();
        } else {
            screenName = targetScreen;
            displayExpanded = false;
        }
    }

    function openDisplay(targetScreen: string): void {
        screenName = targetScreen;
        displayExpanded = true;
    }

    function close(): void {
        screenName = "";
        displayExpanded = false;
    }

    function isOpen(targetScreen: string): bool {
        return screenName === targetScreen;
    }
}
