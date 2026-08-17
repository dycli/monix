pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Item {
    id: root

    property real scaleFactor: 1

    readonly property color batteryColor: PowerService.percentage <= 15 && !PowerService.charging
        ? Style.lowBatteryColor : Style.foregroundColor

    width: content.implicitWidth
    height: Math.round(24 * scaleFactor)

    Row {
        id: content

        anchors.centerIn: parent
        spacing: Math.round(4 * root.scaleFactor)

        Text {
            width: Math.round(12 * root.scaleFactor)
            height: Math.round(12 * root.scaleFactor)
            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Math.round(10 * root.scaleFactor)
                weight: 400
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering
            text: ""
            visible: PowerService.idleInhibited
        }

        BatteryIcon {
            anchors.verticalCenter: parent.verticalCenter
            color: root.batteryColor
            percentage: PowerService.percentage
            charging: PowerService.charging
            full: PowerService.full
            scaleFactor: root.scaleFactor
            visible: PowerService.hasBattery
        }

        Text {
            width: Math.round(16 * root.scaleFactor)
            height: Math.round(16 * root.scaleFactor)
            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Math.round(Style.iconFontSize * root.scaleFactor)
                weight: Style.fontWeight
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering
            text: "󰚥"
            visible: !PowerService.hasBattery
        }
    }

    PowerPanel {
        id: panel
        anchorItem: root
    }

    MouseArea {
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: event => {
            if (event.button === Qt.MiddleButton) {
                PowerService.idleInhibited = !PowerService.idleInhibited;
            } else if (event.button === Qt.RightButton) {
                PowerService.cycleProfile();
            } else {
                panel.open = !panel.open;
            }
        }
    }
}
