pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    property int selectedIndex: 0
    readonly property var results: ClipboardState.filtered(search.text)

    implicitWidth: content.implicitWidth
    implicitHeight: 24

    Component.onCompleted: {
        ClipboardState.refresh();
        focusTimer.start();
    }

    Timer {
        id: focusTimer
        interval: 0
        onTriggered: search.forceActiveFocus()
    }

    Row {
        id: content

        height: 24
        spacing: Style.rightSectionGap

        Item {
            width: 150
            height: 24

            Text {
                anchors {
                    left: parent.left
                    leftMargin: 5
                    verticalCenter: parent.verticalCenter
                }
                color: Style.panelMutedColor
                font {
                    family: Style.fontFamily
                    pixelSize: Style.textFontSize
                    weight: Style.fontWeight
                }
                text: "Clipboard"
                visible: search.text.length === 0
            }

            TextInput {
                id: search

                anchors {
                    fill: parent
                    leftMargin: 5
                    rightMargin: 5
                }
                color: Style.foregroundColor
                clip: true
                font {
                    family: Style.fontFamily
                    pixelSize: Style.textFontSize
                    weight: Style.fontWeight
                }
                verticalAlignment: TextInput.AlignVCenter
                onTextChanged: root.selectedIndex = 0

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
                        root.selectedIndex = Math.min(root.results.length - 1, root.selectedIndex + 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
                        root.selectedIndex = Math.max(0, root.selectedIndex - 1);
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
                    bottomMargin: 3
                }
                height: 1
                color: Style.foregroundColor
            }
        }

        Repeater {
            model: root.results

            delegate: BarModeButton {
                required property int index
                required property var modelData

                active: index === root.selectedIndex
                label: modelData.preview
                maximumWidth: 170
                secondaryInteractive: true
                onActivated: ClipboardState.paste(modelData.entryId)
                onSecondaryActivated: ClipboardState.remove(modelData.entryId)
            }
        }
    }
}
