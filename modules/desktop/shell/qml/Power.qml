pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Item {
    id: root

    readonly property color batteryColor: PowerService.percentage <= 15 && !PowerService.charging
        ? Style.lowBatteryColor : Style.foregroundColor

    width: content.implicitWidth
    height: 24

    Row {
        id: content

        anchors.centerIn: parent
        spacing: 4

        Text {
            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: 10
                weight: Font.Bold
            }
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
            visible: PowerService.hasBattery
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.iconFontSize
                weight: Style.fontWeight
            }
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
