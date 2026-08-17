import QtQuick
import Quickshell

Item {
    id: root

    property real scaleFactor: 1

    width: Math.round(28 * scaleFactor)
    height: Math.round(24 * scaleFactor)

    Item {
        width: Math.round(15 * root.scaleFactor)
        height: Math.round(14 * root.scaleFactor)
        anchors.centerIn: parent

        Rectangle {
            width: parent.width
            height: Math.max(1, Math.round(root.scaleFactor))
            y: 4 * root.scaleFactor
            color: Style.foregroundColor
        }

        Rectangle {
            width: 4 * root.scaleFactor
            height: 4 * root.scaleFactor
            x: 3 * root.scaleFactor
            y: 2.5 * root.scaleFactor
            radius: 2 * root.scaleFactor
            color: Style.foregroundColor
        }

        Rectangle {
            width: parent.width
            height: Math.max(1, Math.round(root.scaleFactor))
            y: 10 * root.scaleFactor
            color: Style.foregroundColor
        }

        Rectangle {
            width: 4 * root.scaleFactor
            height: 4 * root.scaleFactor
            x: 9 * root.scaleFactor
            y: 8.5 * root.scaleFactor
            radius: 2 * root.scaleFactor
            color: Style.foregroundColor
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached(["dms", "ipc", "call", "control-center", "toggle"])
    }
}
