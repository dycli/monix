pragma Singleton

import QtQuick

QtObject {
    id: root

    property string activeMode: ""
    property string screenName: ""
    property bool wantsKeyboard: false

    function open(mode: string, targetScreen: string): void {
        activeMode = mode;
        screenName = targetScreen;
        wantsKeyboard = false;
    }

    function toggle(mode: string, targetScreen: string): void {
        if (activeMode === mode && screenName === targetScreen)
            close();
        else
            open(mode, targetScreen);
    }

    function close(): void {
        activeMode = "";
        screenName = "";
        wantsKeyboard = false;
    }

    function isActive(targetScreen: string): bool {
        return activeMode !== "" && screenName === targetScreen;
    }
}
