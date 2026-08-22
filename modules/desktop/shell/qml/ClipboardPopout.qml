pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

PopupWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    property int selectedIndex: 0
    readonly property var results: ClipboardState.filtered(search.text)
    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
    readonly property real screenHeight: anchorWindow && anchorWindow.screen
        ? anchorWindow.screen.height : 468
    readonly property real maximumHeight: Math.max(320, screenHeight
        - Style.barHeight - Style.popupBarGap - Style.popupScreenMargin)

    color: "transparent"
    implicitWidth: 420
    implicitHeight: Math.min(420, maximumHeight)
    grabFocus: true
    visible: ClipboardPanelService.isOpen(screenName)
    mask: Region {
        width: root.width
        height: root.height
        radius: Style.popupRadius
    }
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

    anchor {
        id: popupAnchor

        window: root.anchorItem ? root.anchorItem.QsWindow.window : null
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
            if (!root.anchorItem || !window)
                return;
            popupAnchor.rect.x = Math.round(window.width - root.implicitWidth
                - Style.popupScreenMargin);
            popupAnchor.rect.y = window.height + Style.popupBarGap;
        }
    }

    PopupSurface {

        Column {
            anchors {
                fill: parent
                margins: 16
            }
            spacing: 12

            Item {
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
                height: parent.height - 42
                clip: true
                spacing: 4
                model: root.results

                onCountChanged: root.selectedIndex = Math.max(0,
                    Math.min(count - 1, root.selectedIndex))

                delegate: Rectangle {
                    id: entryRow

                    required property int index
                    required property var modelData

                    width: ListView.view.width
                    height: 42
                    radius: 6
                    color: index === root.selectedIndex
                        ? Qt.rgba(1, 1, 1, 0.08) : "transparent"

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
                    text: "No clipboard history"
                    visible: root.results.length === 0
                }
            }
        }
    }
}
