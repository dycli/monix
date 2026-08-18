pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

Item {
    id: root

    signal moved(real value)
    signal iconActivated
    signal secondaryActivated

    property string icon: ""
    property real value: 0
    property bool available: true
    property bool iconAvailable: available

    implicitWidth: 82
    implicitHeight: 24

    Text {
        id: iconItem

        anchors {
            left: parent.left
            verticalCenter: parent.verticalCenter
        }
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.iconFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: root.icon
        opacity: root.iconAvailable ? 1 : 0.45
    }

    MouseArea {
        anchors.fill: iconItem
        cursorShape: Qt.PointingHandCursor
        enabled: root.iconAvailable
        onClicked: root.iconActivated()
    }

    Slider {
        id: slider

        anchors {
            left: iconItem.right
            leftMargin: 6
            right: parent.right
            verticalCenter: parent.verticalCenter
        }
        enabled: root.available
        opacity: root.available ? 1 : 0.45
        from: 0
        to: 1
        value: root.value
        onMoved: root.moved(value)

        background: Rectangle {
            x: slider.leftPadding
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth
            height: 2
            color: Style.inactiveWorkspaceColor
            opacity: 0.45

            Rectangle {
                width: parent.width * slider.visualPosition
                height: parent.height
                color: Style.foregroundColor
            }
        }

        handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 7
            height: 7
            radius: width / 2
            color: Style.foregroundColor
        }
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        enabled: root.available
        onTapped: root.secondaryActivated()
    }
}
