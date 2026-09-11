pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

PanelWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    property int selectedIndex: 0
    property int popupLeft: 0

    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
    readonly property bool searching: search.text.trim().length > 0
    readonly property var results: searching
        ? LauncherService.results(search.text, 30) : LauncherService.recent(12)

    function moveSelection(offset: int): void {
        if (results.length === 0)
            return;
        selectedIndex = (selectedIndex + offset + results.length) % results.length;
        entries.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function launchSelected(): void {
        if (results.length > 0)
            LauncherService.launch(results[selectedIndex]);
    }

    color: "transparent"
    implicitWidth: 250
    implicitHeight: 320
    screen: anchorWindow ? anchorWindow.screen : null
    visible: LauncherService.isOpen(screenName)

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

    onResultsChanged: selectedIndex = Math.min(selectedIndex,
        Math.max(0, results.length - 1))
    onVisibleChanged: {
        if (visible) {
            if (anchorWindow)
                popupLeft = Math.round(anchorWindow.itemPosition(anchorItem).x);
            search.text = "";
            selectedIndex = 0;
            focusTimer.start();
        } else if (LauncherService.isOpen(screenName)) {
            LauncherService.close();
        }
    }

    HyprlandFocusGrab {
        active: root.visible
        windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
        onCleared: LauncherService.close()
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
                margins: 8
            }
            spacing: 6

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
                    renderType: Text.NativeRendering
                    text: "Find applications"
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
                        if (event.key === Qt.Key_Escape) {
                            LauncherService.close();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down) {
                            root.moveSelection(1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up) {
                            root.moveSelection(-1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.launchSelected();
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
                height: parent.height - 36
                clip: true
                spacing: 2
                model: root.results

                delegate: Rectangle {
                    id: resultRow

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
                            right: parent.right
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
                        text: resultRow.modelData.name
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onEntered: root.selectedIndex = resultRow.index
                        onClicked: event => {
                            const mode = event.button === Qt.RightButton
                                ? "floating" : (event.button === Qt.MiddleButton
                                    ? "workspace" : "normal");
                            LauncherService.launch(resultRow.modelData, mode);
                        }
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
                    text: root.searching ? "No applications" : "No recent applications"
                    visible: root.results.length === 0
                }
            }
        }
    }
}
