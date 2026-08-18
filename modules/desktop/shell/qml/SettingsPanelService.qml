pragma Singleton

import QtQuick

QtObject {
    property string screenName: ""

    function toggle(targetScreen: string): void {
        screenName = screenName === targetScreen ? "" : targetScreen;
    }

    function close(): void {
        screenName = "";
    }

    function isOpen(targetScreen: string): bool {
        return screenName === targetScreen;
    }
}
