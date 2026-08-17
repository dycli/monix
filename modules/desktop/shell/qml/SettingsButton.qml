import QtQuick
import Quickshell

Item {
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
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(["dms", "ipc", "call", "control-center", "toggle"])
    }
}
