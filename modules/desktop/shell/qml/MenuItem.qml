pragma ComponentBehavior: Bound

import QtQuick

Rectangle {
    id: root

    signal activated

    required property string label
    property string detail: ""

    implicitHeight: 26
    color: pointer.containsMouse ? Qt.rgba(1, 1, 1, 0.09) : "transparent"

    Text {
        anchors {
            left: parent.left
            leftMargin: 10
            right: detailItem.left
            rightMargin: 10
            verticalCenter: parent.verticalCenter
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
        id: detailItem

        anchors {
            right: parent.right
            rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: root.detail
        visible: root.detail.length > 0
    }

    MouseArea {
        id: pointer

        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: root.activated()
    }
}
