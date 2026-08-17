pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    signal activated

    property string label: ""
    property bool active: false
    property bool enabled: true
    property real maximumWidth: 0

    implicitWidth: maximumWidth > 0
        ? Math.min(labelItem.implicitWidth + 10, maximumWidth)
        : labelItem.implicitWidth + 10
    implicitHeight: 24
    opacity: enabled ? 1 : 0.45

    Text {
        id: labelItem

        anchors.centerIn: parent
        width: root.maximumWidth > 0 ? root.width - 10 : implicitWidth
        color: Style.foregroundColor
        elide: Text.ElideRight
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: root.label
    }

    Rectangle {
        width: Math.min(labelItem.implicitWidth, root.width - 10)
        height: 1
        anchors {
            bottom: parent.bottom
            bottomMargin: 3
            horizontalCenter: parent.horizontalCenter
        }
        color: Style.foregroundColor
        visible: root.active
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: root.enabled
        onClicked: root.activated()
    }
}
