pragma Singleton

import QtQuick

QtObject {
    property string screenName: ""
    property bool emojiOpen: false

    function toggle(targetScreen: string): void {
        if (screenName === targetScreen) {
            close();
            return;
        }

        screenName = targetScreen;
        emojiOpen = false;
    }

    function close(): void {
        screenName = "";
        emojiOpen = false;
    }

    function isOpen(targetScreen: string): bool {
        return screenName === targetScreen;
    }

    function showEmoji(targetScreen: string): void {
        if (screenName === targetScreen)
            emojiOpen = true;
    }

    function hideEmoji(): void {
        emojiOpen = false;
    }
}
