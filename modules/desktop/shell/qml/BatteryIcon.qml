pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    property int percentage: 0
    property bool charging: false
    property bool full: false
    property color color: Style.foregroundColor
    property real scaleFactor: 1

    implicitWidth: Math.round(21 * scaleFactor)
    implicitHeight: Math.round(12 * scaleFactor)

    Rectangle {
        id: body

        width: Math.round(20 * root.scaleFactor)
        height: Math.round(10 * root.scaleFactor)
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        radius: 2.5 * root.scaleFactor
        clip: true
        color: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.3)

        Rectangle {
            anchors {
                left: parent.left
                verticalCenter: parent.verticalCenter
            }

            width: body.width * root.percentage / 100
            height: body.height
            radius: 0
            topLeftRadius: body.radius
            bottomLeftRadius: body.radius
            color: root.color
        }

        Text {
            anchors.fill: parent
            color: Style.panelColor
            font {
                family: Style.fontFamily
                pixelSize: Math.max(2, Math.round(8 * root.scaleFactor / 2) * 2)
                weight: Font.Bold
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering
            text: root.charging ? "" : "✓"
            visible: root.charging || root.full
        }
    }

    Rectangle {
        width: Math.max(1, Math.round(root.scaleFactor))
        height: Math.round(4 * root.scaleFactor)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        radius: 0.5 * root.scaleFactor
        color: root.color
    }
}
