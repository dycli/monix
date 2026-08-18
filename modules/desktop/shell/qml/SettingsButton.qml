import QtQuick

Item {
    id: root

    signal menuToggleRequested

    readonly property bool hovered: pointer.containsMouse

    width: 28
    height: 24

    Item {
        width: 15
        height: 14
        anchors.centerIn: parent

        Rectangle {
            width: parent.width
            height: 1
            y: 4
            color: Style.foregroundColor
        }

        Rectangle {
            width: 4
            height: 4
            x: 3
            y: 2.5
            radius: 2
            color: Style.foregroundColor
        }

        Rectangle {
            width: parent.width
            height: 1
            y: 10
            color: Style.foregroundColor
        }

        Rectangle {
            width: 4
            height: 4
            x: 9
            y: 8.5
            radius: 2
            color: Style.foregroundColor
        }
    }

    MouseArea {
        id: pointer

        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: event => {
            if (event.button === Qt.MiddleButton) {
                PowerService.idleInhibited = !PowerService.idleInhibited;
            } else {
                root.menuToggleRequested();
            }
        }
    }
}
