pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets

Item {
    id: root

    required property string screenName

    readonly property bool active: BarModeService.activeMode === "launcher"
        && BarModeService.screenName === screenName
    readonly property int resultWidth: 132
    readonly property int resultLimit: Math.max(1,
        Math.min(7, Math.floor((width - searchBox.width - 8) / resultWidth)))
    readonly property var results: LauncherService.results(search.text, resultLimit)

    property int selectedIndex: 0

    visible: active

    onActiveChanged: {
        if (active) {
            search.text = "";
            selectedIndex = 0;
            focusTimer.restart();
        }
    }

    onResultsChanged: selectedIndex = Math.min(selectedIndex,
        Math.max(0, results.length - 1))

    function moveSelection(offset: int): void {
        if (results.length === 0)
            return;
        selectedIndex = (selectedIndex + offset + results.length) % results.length;
    }

    function launchSelected(): void {
        if (results.length > 0)
            LauncherService.launch(results[selectedIndex]);
    }

    Timer {
        id: focusTimer
        interval: 0
        onTriggered: search.forceActiveFocus()
    }

    Row {
        anchors.fill: parent
        spacing: 8

        Item {
            id: searchBox

            width: Math.min(180, Math.max(120, root.width * 0.28))
            height: parent.height

            Text {
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                color: Style.inactiveWorkspaceColor
                font {
                    family: Style.fontFamily
                    pixelSize: Style.textFontSize
                    weight: Style.fontWeight
                }
                renderType: Text.NativeRendering
                text: "Launch"
                visible: search.text.length === 0
            }

            TextInput {
                id: search

                anchors.fill: parent
                color: Style.foregroundColor
                clip: true
                font {
                    family: Style.fontFamily
                    pixelSize: Style.textFontSize
                    weight: Style.fontWeight
                }
                selectionColor: Style.foregroundColor
                selectedTextColor: "#000000"
                verticalAlignment: TextInput.AlignVCenter
                onTextChanged: root.selectedIndex = 0

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Right || event.key === Qt.Key_Down
                            || (event.key === Qt.Key_Tab
                                && !(event.modifiers & Qt.ShiftModifier))) {
                        root.moveSelection(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up
                               || (event.key === Qt.Key_Backtab)
                               || (event.key === Qt.Key_Tab
                                   && (event.modifiers & Qt.ShiftModifier))) {
                        root.moveSelection(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.launchSelected();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape) {
                        BarModeService.close();
                        event.accepted = true;
                    }
                }
            }

            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    bottomMargin: 3
                }
                height: 1
                color: Style.foregroundColor
            }
        }

        Item {
            width: Math.max(0, parent.width - searchBox.width - parent.spacing)
            height: parent.height
            clip: true

            Row {
                anchors.fill: parent
                spacing: 0

                Repeater {
                    model: root.results

                    delegate: MouseArea {
                        id: result

                        required property int index
                        required property var modelData

                        width: root.resultWidth
                        height: parent.height
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onEntered: root.selectedIndex = index
                        onClicked: LauncherService.launch(modelData)

                        Row {
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                            }
                            spacing: 5

                            IconImage {
                                id: appIcon

                                width: 14
                                height: 14
                                source: Quickshell.iconPath(result.modelData.icon,
                                    "application-x-executable")
                                asynchronous: true
                                smooth: true
                                mipmap: true
                                layer.enabled: true
                                layer.effect: MultiEffect {
                                    saturation: -1
                                    colorization: 1
                                    colorizationColor: result.index === root.selectedIndex
                                        ? Style.foregroundColor : Style.inactiveWorkspaceColor
                                }
                            }

                            Text {
                                width: Math.max(0, parent.width - appIcon.width - parent.spacing)
                                anchors.verticalCenter: parent.verticalCenter
                                color: result.index === root.selectedIndex
                                    ? Style.foregroundColor : Style.inactiveWorkspaceColor
                                elide: Text.ElideRight
                                font {
                                    family: Style.fontFamily
                                    pixelSize: Style.textFontSize
                                    weight: result.index === root.selectedIndex
                                        ? Font.DemiBold : Style.fontWeight
                                }
                                renderType: Text.NativeRendering
                                text: result.modelData.name
                            }
                        }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    color: Style.inactiveWorkspaceColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.textFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: "No applications"
                    visible: root.results.length === 0
                }
            }
        }
    }
}
