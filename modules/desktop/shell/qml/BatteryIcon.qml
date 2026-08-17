pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    property int percentage: 0
    property bool charging: false
    property bool full: false
    property color color: Style.foregroundColor

    implicitWidth: 21
    implicitHeight: 12

    Rectangle {
        id: body

        width: 20
        height: 10
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        radius: 2.5
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
                pixelSize: 8
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
        width: 1
        height: 4
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        radius: 0.5
        color: root.color
    }
}
