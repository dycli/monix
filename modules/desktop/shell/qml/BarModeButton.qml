pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    signal activated
    signal secondaryActivated

    property string icon: ""
    property string label: ""
    property bool active: false
    property bool enabled: true
    property bool interactive: true
    property bool secondaryInteractive: false
    property bool showActiveIndicator: true
    property real maximumWidth: 0

    readonly property real contentSpacing: icon.length > 0 && label.length > 0 ? 4 : 0
    readonly property real naturalContentWidth: iconItem.implicitWidth + contentSpacing + labelItem.implicitWidth

    implicitWidth: maximumWidth > 0 ? Math.min(naturalContentWidth + 10, maximumWidth) : naturalContentWidth + 10
    implicitHeight: 24
    opacity: enabled ? 1 : 0.45

    Row {
        id: content

        anchors.centerIn: parent
        spacing: root.contentSpacing

        Text {
            id: iconItem

            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.iconFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: root.icon
            visible: root.icon.length > 0
        }

        Text {
            id: labelItem

            anchors.verticalCenter: parent.verticalCenter
            width: root.maximumWidth > 0
                ? Math.max(0, root.width - 10 - iconItem.implicitWidth - root.contentSpacing)
                : implicitWidth
            color: Style.foregroundColor
            elide: Text.ElideRight
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: root.label
            visible: root.label.length > 0
        }
    }

    Rectangle {
        width: Math.min(root.naturalContentWidth, root.width - 10)
        height: 1
        anchors {
            bottom: parent.bottom
            bottomMargin: 3
            horizontalCenter: parent.horizontalCenter
        }
        color: Style.foregroundColor
        visible: root.active && root.showActiveIndicator
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: (root.interactive ? Qt.LeftButton : Qt.NoButton)
            | (root.secondaryInteractive ? Qt.RightButton : Qt.NoButton)
        cursorShape: root.enabled && (root.interactive || root.secondaryInteractive)
            ? Qt.PointingHandCursor
            : Qt.ArrowCursor
        enabled: root.enabled && (root.interactive || root.secondaryInteractive)
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                root.secondaryActivated();
            else
                root.activated();
        }
    }
}
