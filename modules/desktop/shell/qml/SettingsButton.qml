import QtQuick

Item {
    id: root

    signal menuToggleRequested

    property real scaleFactor: 1
    readonly property bool hovered: pointer.containsMouse

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
        id: pointer

        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: root.menuToggleRequested()
    }
}
