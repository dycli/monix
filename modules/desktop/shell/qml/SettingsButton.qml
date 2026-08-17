import QtQuick
import Quickshell

Rectangle {
    id: root

    width: 28
    height: 24
    radius: 2
    color: mouse.containsMouse ? "#272a31" : "transparent"

    Item {
        width: 15
        height: 14
        anchors.centerIn: parent

        Rectangle {
            width: parent.width
            height: 1
            y: 4
            color: "#aeb3bd"
        }

        Rectangle {
            width: 4
            height: 4
            x: 3
            y: 2.5
            radius: 2
            color: "#eef0f4"
        }

        Rectangle {
            width: parent.width
            height: 1
            y: 10
            color: "#aeb3bd"
        }

        Rectangle {
            width: 4
            height: 4
            x: 9
            y: 8.5
            radius: 2
            color: "#eef0f4"
        }
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: Quickshell.execDetached(["dms", "ipc", "call", "settings", "open"])
    }
}
