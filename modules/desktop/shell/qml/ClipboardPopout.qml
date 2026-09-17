pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    required property string screenName
    required property var targetScreen
    required property int popupLeft
    required property int popupTop

    property int selectedIndex: 0

    readonly property var results: ClipboardState.filtered(search.text)

    color: "transparent"
    implicitWidth: 250
    implicitHeight: 300
    screen: targetScreen
    visible: ClipboardPanelService.isOpen(screenName)
        && ClipboardPanelService.clipboardOpen

    anchors {
        top: true
        left: true
    }
    margins {
        left: popupLeft
        top: popupTop
    }
    exclusiveZone: 0

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "kestrel:popout"
    WlrLayershell.keyboardFocus: root.visible
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    onVisibleChanged: {
        if (visible) {
            selectedIndex = 0;
            search.text = "";
            ClipboardState.refresh();
            focusTimer.start();
        }
    }

    Timer {
        id: focusTimer

        interval: 0
        onTriggered: search.forceActiveFocus()
    }

    PopupSurface {
        Column {
            anchors {
                fill: parent
                margins: 6
            }
            spacing: 6

            Item {
                id: searchBox

                width: parent.width
                height: 30

                Text {
                    anchors {
                        left: parent.left
                        right: clearButton.left
                        rightMargin: 12
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

                    anchors {
                        left: parent.left
                        right: clearButton.left
                        rightMargin: 12
                        top: parent.top
                        bottom: parent.bottom
                    }
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
                        if (event.key === Qt.Key_Escape) {
                            ClipboardPanelService.close();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down && root.results.length > 0) {
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

                Text {
                    id: clearButton

                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                    }
                    color: Style.panelMutedColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.smallFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: "Clear"
                    visible: ClipboardState.entries.length > 0

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: ClipboardState.clear()
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
                height: Math.max(0, parent.height - searchBox.height - 6)
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
                    radius: Style.popupRadius

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
