pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    readonly property bool hovered: pointer.containsMouse
    readonly property color batteryColor: PowerService.percentage <= 15 && !PowerService.charging
        ? Style.lowBatteryColor : Style.foregroundColor

    width: content.implicitWidth
    height: 24

    Row {
        id: content

        anchors.centerIn: parent
        spacing: 4

        Text {
            width: 12
            height: 12
            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: 10
                weight: 500
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
            visible: PowerService.hasBattery
        }

        Text {
            width: 16
            height: 16
            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.iconFontSize
                weight: Style.fontWeight
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering
            text: "󰚥"
            visible: !PowerService.hasBattery
        }
    }

    MouseArea {
        id: pointer

        acceptedButtons: Qt.MiddleButton | Qt.RightButton
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: event => {
            if (event.button === Qt.MiddleButton) {
                PowerService.idleInhibited = !PowerService.idleInhibited;
                OsdService.showIdleInhibit();
            } else if (event.button === Qt.RightButton) {
                PowerService.cycleProfile();
                OsdService.showPowerProfile();
            }
        }
    }
}
