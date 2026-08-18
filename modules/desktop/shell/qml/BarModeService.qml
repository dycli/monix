pragma Singleton

import QtQuick

QtObject {
    id: root

    property string activeMode: ""
    property string screenName: ""
    property bool wantsKeyboard: false
    property string transientMode: ""
    property string transientScreenName: ""
    property bool transientVisible: false
    property int transientGeneration: 0

    property Timer transientTimer: Timer {
        interval: 1300
        onTriggered: root.hideTransient()
    }

    property Timer transientClearTimer: Timer {
        interval: 190
        onTriggered: {
            root.transientMode = "";
            root.transientScreenName = "";
        }
    }

    function open(mode: string, targetScreen: string, keyboard: bool): void {
        closeTransient();
        activeMode = mode;
        screenName = targetScreen;
        wantsKeyboard = keyboard || false;
    }

    function toggle(mode: string, targetScreen: string, keyboard: bool): void {
        if (activeMode === mode && screenName === targetScreen)
            close();
        else
            open(mode, targetScreen, keyboard);
    }

    function close(): void {
        closeTransient();
        activeMode = "";
        screenName = "";
        wantsKeyboard = false;
    }

    function isActive(targetScreen: string): bool {
        return activeMode !== "" && screenName === targetScreen;
    }

    function flash(mode: string, targetScreen: string): void {
        if (activeMode !== "")
            return;
        transientMode = mode;
        transientScreenName = targetScreen;
        transientVisible = true;
        transientGeneration++;
        transientClearTimer.stop();
        transientTimer.restart();
    }

    function hideTransient(): void {
        transientTimer.stop();
        transientVisible = false;
        transientClearTimer.restart();
    }

    function closeTransient(): void {
        transientTimer.stop();
        transientClearTimer.stop();
        transientVisible = false;
        transientMode = "";
        transientScreenName = "";
    }

    function transientFor(targetScreen: string): string {
        return transientScreenName === targetScreen ? transientMode : "";
    }

    function transientVisibleFor(targetScreen: string): bool {
        return transientVisible && transientScreenName === targetScreen;
    }
}
