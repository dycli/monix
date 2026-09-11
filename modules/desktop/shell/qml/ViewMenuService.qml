pragma Singleton

import QtQuick

QtObject {
    property string screenName: ""
    property bool layoutOpen: false

    function toggle(targetScreen: string): void {
        if (screenName === targetScreen) {
            close();
            return;
        }

        screenName = targetScreen;
        layoutOpen = false;
    }

    function close(): void {
        screenName = "";
        layoutOpen = false;
    }

    function isOpen(targetScreen: string): bool {
        return screenName === targetScreen;
    }

    function showLayout(targetScreen: string): void {
        if (screenName === targetScreen)
            layoutOpen = true;
    }

    function hideLayout(): void {
        layoutOpen = false;
    }
}
