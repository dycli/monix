pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

PopupWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    property int selectedIndex: 0
    property string pendingModifiers: ""
    property string pendingKey: ""

    readonly property var results: ClipboardState.filtered(search.text)

    function sendShortcut(modifiers: string, key: string): void {
        pendingModifiers = modifiers;
        pendingKey = key;
        ClipboardPanelService.close();
        shortcutTimer.restart();
    }

    color: "transparent"
    width: 330
    height: 420
    visible: ClipboardPanelService.isOpen(screenName)
    grabFocus: true

    anchor.item: anchorItem
    anchor.rect.y: anchorItem ? anchorItem.height + Style.popupGap : 0

    onVisibleChanged: {
        if (visible) {
            selectedIndex = 0;
            search.text = "";
            ClipboardState.refresh();
            focusTimer.start();
        } else if (ClipboardPanelService.isOpen(screenName)) {
            ClipboardPanelService.close();
        }
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: ClipboardPanelService.close()
    }

    Timer {
        id: focusTimer

        interval: 0
        onTriggered: search.forceActiveFocus()
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
                        { "label": "Undo", "detail": "Ctrl+Z", "mods": "CTRL", "key": "Z" },
                        { "label": "Redo", "detail": "Ctrl+Shift+Z", "mods": "CTRL SHIFT", "key": "Z" },
                        { "label": "Cut", "detail": "Ctrl+X", "mods": "CTRL", "key": "X" },
                        { "label": "Copy", "detail": "Ctrl+Insert", "mods": "CTRL", "key": "Insert" },
                        { "label": "Paste", "detail": "Shift+Insert", "mods": "SHIFT", "key": "Insert" },
                        { "label": "Select All", "detail": "Ctrl+A", "mods": "CTRL", "key": "A" }
                    ]

                    delegate: MenuItem {
                        required property var modelData

                        width: commands.width
                        label: modelData.label
                        detail: modelData.detail
                        onActivated: root.sendShortcut(modelData.mods, modelData.key)
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Style.panelBorderColor
            }

            Item {
                id: searchBox

                width: parent.width
                height: 30

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    color: Style.panelMutedColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.panelFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: "Search clipboard"
                    visible: search.text.length === 0
                }

                TextInput {
                    id: search

                    anchors.fill: parent
                    color: Style.foregroundColor
                    clip: true
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.panelFontSize
                        weight: Style.fontWeight
                    }
                    selectionColor: Style.foregroundColor
                    selectedTextColor: "#000000"
                    verticalAlignment: TextInput.AlignVCenter
                    onTextChanged: root.selectedIndex = 0

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Down && root.results.length > 0) {
                            root.selectedIndex = Math.min(root.results.length - 1,
                                root.selectedIndex + 1);
                            entries.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up && root.results.length > 0) {
                            root.selectedIndex = Math.max(0, root.selectedIndex - 1);
                            entries.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                            event.accepted = true;
                        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                && root.results.length > 0) {
                            ClipboardState.paste(root.results[root.selectedIndex].entryId);
                            event.accepted = true;
                        }
                    }
                }

                Rectangle {
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                    }
                    height: 1
                    color: Style.panelBorderColor
                }
            }

            ListView {
                id: entries

                width: parent.width
                height: Math.max(0, parent.height - commands.height - searchBox.height - 21)
                clip: true
                spacing: 2
                model: root.results

                onCountChanged: root.selectedIndex = Math.max(0,
                    Math.min(count - 1, root.selectedIndex))

                delegate: Rectangle {
                    id: entryRow

                    required property int index
                    required property var modelData

                    width: ListView.view.width
                    height: 30
                    color: index === root.selectedIndex
                        ? Qt.rgba(1, 1, 1, 0.09) : "transparent"

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 10
                            right: removeButton.left
                            rightMargin: 10
                            verticalCenter: parent.verticalCenter
                        }
                        color: Style.foregroundColor
                        elide: Text.ElideRight
                        font {
                            family: Style.fontFamily
                            pixelSize: Style.panelFontSize
                            weight: Style.fontWeight
                        }
                        renderType: Text.NativeRendering
                        text: entryRow.modelData.preview
                    }

                    Text {
                        id: removeButton

                        anchors {
                            right: parent.right
                            rightMargin: 8
                            verticalCenter: parent.verticalCenter
                        }
                        color: Style.panelMutedColor
                        font {
                            family: Style.fontFamily
                            pixelSize: 14
                            weight: Style.fontWeight
                        }
                        text: "×"

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -8
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ClipboardState.remove(entryRow.modelData.entryId)
                        }
                    }

                    MouseArea {
                        anchors {
                            left: parent.left
                            right: removeButton.left
                            top: parent.top
                            bottom: parent.bottom
                        }
                        cursorShape: Qt.PointingHandCursor
                        onClicked: ClipboardState.paste(entryRow.modelData.entryId)
                    }
                }

                Text {
                    anchors.centerIn: parent
                    color: Style.panelMutedColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.panelFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: "No clipboard history"
                    visible: root.results.length === 0
                }
            }
        }
    }
}
