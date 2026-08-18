pragma ComponentBehavior: Bound

import QtQuick

Rectangle {
    id: root

    signal activated
    signal secondaryActivated

    property string icon: ""
    property string label: ""
    property string detail: ""
    property bool active: false
    property bool interactive: true
    property bool secondaryInteractive: false

    implicitHeight: 38
    radius: 8
    color: active || pointer.containsMouse
        ? Qt.rgba(1, 1, 1, active ? 0.11 : 0.06) : "transparent"
    opacity: interactive ? 1 : 0.45

    Text {
        id: iconItem

        anchors {
            left: parent.left
            leftMargin: 10
            verticalCenter: parent.verticalCenter
        }
        width: root.icon.length > 0 ? 20 : 0
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.iconFontSize
            weight: Style.fontWeight
        }
        horizontalAlignment: Text.AlignHCenter
        renderType: Text.NativeRendering
        text: root.icon
        visible: root.icon.length > 0
    }

    Text {
        anchors {
            left: iconItem.right
            leftMargin: root.icon.length > 0 ? 10 : 0
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
        acceptedButtons: (root.interactive ? Qt.LeftButton : Qt.NoButton)
            | (root.secondaryInteractive ? Qt.RightButton : Qt.NoButton)
        cursorShape: root.interactive || root.secondaryInteractive
            ? Qt.PointingHandCursor : Qt.ArrowCursor
        hoverEnabled: true
        onClicked: event => {
            if (event.button === Qt.RightButton)
                root.secondaryActivated();
            else
                root.activated();
        }
    }
}
