pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    signal moved(real value)
    signal iconActivated

    property string icon: ""
    property string label: ""
    property real value: 0
    property bool available: true
    property bool iconAvailable: available

    implicitHeight: 52
    opacity: available || iconAvailable ? 1 : 0.45

    Item {
        id: iconSlot

        anchors {
            left: parent.left
            top: parent.top
            bottom: parent.bottom
        }
        width: 28

        Text {
            anchors.fill: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.iconFontSize
                weight: Style.fontWeight
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering
            text: root.icon
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: root.iconAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: root.iconAvailable
            onClicked: root.iconActivated()
        }
    }

    Item {
        anchors {
            left: iconSlot.right
            leftMargin: 10
            right: parent.right
            top: parent.top
            bottom: parent.bottom
        }

        Text {
            anchors {
                left: parent.left
                right: percentage.left
                rightMargin: 8
                top: parent.top
                topMargin: 4
            }
            color: Style.foregroundColor
            elide: Text.ElideRight
            font {
                family: Style.fontFamily
                pixelSize: Style.panelFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: root.label
        }

        Text {
            id: percentage

            anchors {
                right: parent.right
                top: parent.top
                topMargin: 5
            }
            color: Style.panelMutedColor
            font {
                family: Style.fontFamily
                pixelSize: Style.smallFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: Math.round(Math.max(0, Math.min(1, root.value)) * 100) + "%"
        }

        Item {
            id: track

            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                bottomMargin: 8
            }
            height: 16
            opacity: root.available ? 1 : 0.45

            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                height: 2
                color: Style.inactiveWorkspaceColor
                opacity: 0.45

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, root.value))
                    height: parent.height
                    color: Style.foregroundColor
                }
            }

            Rectangle {
                id: handle

                x: Math.round(Math.max(0, Math.min(1, root.value)) * (parent.width - width))
                anchors.verticalCenter: parent.verticalCenter
                width: 8
                height: 8
                radius: width / 2
                color: Style.foregroundColor
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                cursorShape: root.available ? Qt.PointingHandCursor : Qt.ArrowCursor
                enabled: root.available
                preventStealing: true

                function moveTo(pointerX: real): void {
                    const travel = Math.max(1, width - handle.width);
                    root.moved(Math.max(0, Math.min(1,
                        (pointerX - handle.width / 2) / travel)));
                }

                onPressed: event => moveTo(event.x)
                onPositionChanged: event => {
                    if (pressed)
                        moveTo(event.x);
                }
            }
        }
    }
}
