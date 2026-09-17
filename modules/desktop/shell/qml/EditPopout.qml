pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

PanelWindow {
    id: root

    required property Item anchorItem
    required property string screenName
    required property var clipboardWindow
    required property var emojiWindow

    property int popupLeft: 0
    property string pendingModifiers: ""
    property string pendingKey: ""

    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
    readonly property int clipboardPopupTop: Style.popupGap + content.y
        + commands.y + clipboardItem.y
    readonly property int emojiPopupTop: Style.popupGap + content.y
        + commands.y + emojiItem.y

    function sendShortcut(modifiers: string, key: string): void {
        pendingModifiers = modifiers;
        pendingKey = key;
        ClipboardPanelService.close();
        shortcutTimer.restart();
    }

    color: "transparent"
    implicitWidth: 250
    implicitHeight: commands.implicitHeight + 12
    screen: anchorWindow ? anchorWindow.screen : null
    visible: ClipboardPanelService.isOpen(screenName)

    anchors {
        top: true
        left: true
    }
    margins {
        left: popupLeft
        top: Style.popupGap
    }
    exclusiveZone: 0

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "kestrel:popout"
    WlrLayershell.keyboardFocus: root.visible
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    onVisibleChanged: {
        if (visible) {
            if (anchorWindow)
                popupLeft = Math.round(anchorWindow.itemPosition(anchorItem).x);
        } else if (ClipboardPanelService.isOpen(screenName)) {
            ClipboardPanelService.close();
        }
    }

    HyprlandFocusGrab {
        active: root.visible
        windows: root.anchorWindow
            ? [root, root.clipboardWindow, root.emojiWindow, root.anchorWindow]
            : [root, root.clipboardWindow, root.emojiWindow]
        onCleared: ClipboardPanelService.close()
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: ClipboardPanelService.close()
    }

    Timer {
        id: shortcutTimer

        interval: 60
        onTriggered: Hyprland.dispatch("hl.dsp.send_shortcut({ mods = "
            + JSON.stringify(root.pendingModifiers) + ", key = "
            + JSON.stringify(root.pendingKey) + " })")
    }

    PopupSurface {
        Column {
            id: content

            anchors {
                fill: parent
                margins: 6
            }
            spacing: 6

            Column {
                id: commands

                width: parent.width
                spacing: 2

                Repeater {
                    model: [
                        { "label": "Undo", "mods": "CTRL", "key": "Z" },
                        { "label": "Redo", "mods": "CTRL SHIFT", "key": "Z" },
                        { "label": "Cut", "mods": "CTRL", "key": "X" },
                        { "label": "Copy", "mods": "CTRL", "key": "Insert" },
                        { "label": "Paste", "mods": "SHIFT", "key": "Insert" },
                        { "label": "Select All", "mods": "CTRL", "key": "A" }
                    ]

                    delegate: MenuItem {
                        required property var modelData

                        width: commands.width
                        label: modelData.label
                        onHoveredChanged: if (hovered) {
                            ClipboardPanelService.hideClipboard();
                            ClipboardPanelService.hideEmoji();
                        }
                        onActivated: root.sendShortcut(modelData.mods, modelData.key)
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Style.panelBorderColor
                }

                MenuItem {
                    id: clipboardItem

                    width: parent.width
                    label: "Clipboard"
                    detail: "›"
                    onHoveredChanged: if (hovered)
                        ClipboardPanelService.showClipboard(root.screenName)
                    onActivated: ClipboardPanelService.showClipboard(root.screenName)
                }

                MenuItem {
                    id: emojiItem

                    width: parent.width
                    label: "Emoji"
                    detail: "›"
                    onHoveredChanged: if (hovered)
                        ClipboardPanelService.showEmoji(root.screenName)
                    onActivated: ClipboardPanelService.showEmoji(root.screenName)
                }
            }
        }
    }
}
