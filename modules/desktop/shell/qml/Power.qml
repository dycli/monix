pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    signal activated

    readonly property bool hovered: pointer.containsMouse
    readonly property color batteryColor: PowerService.percentage <= 15 && !PowerService.charging
        ? Style.lowBatteryColor : Style.foregroundColor

    width: content.implicitWidth
    height: 24
    visible: PowerService.hasBattery

    Row {
        id: content

        anchors.centerIn: parent
        spacing: 4

        BatteryIcon {
            anchors.verticalCenter: parent.verticalCenter
            color: root.batteryColor
            percentage: PowerService.percentage
            charging: PowerService.charging
            full: PowerService.full
        }
    }

    MouseArea {
        id: pointer

        acceptedButtons: Qt.LeftButton | Qt.RightButton
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: event => {
            if (event.button === Qt.RightButton) {
                PowerService.cycleProfile();
                OsdService.showPowerProfile();
            } else {
                root.activated();
            }
        }
    }
}
