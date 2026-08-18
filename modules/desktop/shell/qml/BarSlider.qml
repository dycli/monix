pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    signal moved(real value)
    signal iconActivated
    signal secondaryActivated

    property string icon: ""
    property real value: 0
    property bool available: true
    property bool iconAvailable: available

    implicitWidth: 82
    implicitHeight: 24

    Item {
        id: iconSlot

        anchors {
            left: parent.left
            top: parent.top
            bottom: parent.bottom
        }
        width: 16

        Text {
            id: iconItem

            anchors.centerIn: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.iconFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: root.icon
            opacity: root.iconAvailable ? 1 : 0.45
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            enabled: root.iconAvailable
            onClicked: root.iconActivated()
        }
    }

    Item {
        id: track

        anchors {
            left: iconSlot.right
            leftMargin: 6
            right: parent.right
            top: parent.top
            bottom: parent.bottom
        }
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
            width: 7
            height: 7
            radius: width / 2
            color: Style.foregroundColor
        }

        MouseArea {
            id: dragArea

            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor
            enabled: root.available
            preventStealing: true

            function moveTo(pointerX: real): void {
                const travel = Math.max(1, width - handle.width);
                root.moved(Math.max(0, Math.min(1,
                    (pointerX - handle.width / 2) / travel)));
            }

            onPressed: mouse => moveTo(mouse.x)
            onPositionChanged: mouse => {
                if (pressed)
                    moveTo(mouse.x);
            }
        }
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        enabled: root.available
        onTapped: root.secondaryActivated()
    }
}
