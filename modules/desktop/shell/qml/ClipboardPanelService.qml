pragma Singleton

import QtQuick

QtObject {
    property string screenName: ""
    property bool clipboardOpen: false
    property bool emojiOpen: false

    function toggle(targetScreen: string): void {
        if (screenName === targetScreen) {
            close();
            return;
        }

        screenName = targetScreen;
        clipboardOpen = false;
        emojiOpen = false;
    }

    function close(): void {
        screenName = "";
        clipboardOpen = false;
        emojiOpen = false;
    }

    function isOpen(targetScreen: string): bool {
        return screenName === targetScreen;
    }

    function toggleClipboard(targetScreen: string): void {
        if (screenName === targetScreen && clipboardOpen) {
            close();
            return;
        }

        screenName = targetScreen;
        clipboardOpen = true;
        emojiOpen = false;
    }

    function showClipboard(targetScreen: string): void {
        if (screenName === targetScreen) {
            clipboardOpen = true;
            emojiOpen = false;
        }
    }

    function hideClipboard(): void {
        clipboardOpen = false;
    }

    function showEmoji(targetScreen: string): void {
        if (screenName === targetScreen) {
            clipboardOpen = false;
            emojiOpen = true;
        }
    }

    function hideEmoji(): void {
        emojiOpen = false;
    }
}
