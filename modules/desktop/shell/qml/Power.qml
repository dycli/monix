pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.UPower

Rectangle {
    id: root

    readonly property var batteries: UPower.devices.values.filter(device => device.isLaptopBattery && device.ready)
    readonly property var device: batteries[0] || null
    readonly property int percentage: device ? Math.round(device.percentage * 100) : 0

    width: 28
    height: 24
    radius: 2
    color: mouse.containsMouse ? "#272a31" : "transparent"

    Item {
        width: 21
        height: 12
        anchors.centerIn: parent
        visible: root.device !== null

        Item {
            id: batteryBody

            width: 18
            height: 10
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }

                width: Math.max(2, batteryBody.width * root.percentage / 100)
                height: batteryBody.height
                radius: 2
                color: root.percentage <= 15 ? Style.lowBatteryColor : Style.foregroundColor
            }
        }

        Rectangle {
            width: 2
            height: 4
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            radius: 1
            color: root.percentage <= 15 ? Style.lowBatteryColor : Style.foregroundColor
        }
    }

    Text {
        anchors.centerIn: parent
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.iconFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "⏻"
        visible: root.device === null
    }

    MouseArea {
        id: mouse

        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: event => {
            if (event.button === Qt.MiddleButton) {
                Quickshell.execDetached(["dms", "ipc", "call", "inhibit", "toggle"]);
            } else if (root.device && event.button === Qt.RightButton) {
                Quickshell.execDetached(["dms", "ipc", "call", "powerprofile", "cycle"]);
            } else if (root.device) {
                Quickshell.execDetached(["dms", "ipc", "call", "powerprofile", "toggle"]);
            } else if (event.button === Qt.LeftButton) {
                Quickshell.execDetached(["dms", "ipc", "call", "powermenu", "toggle"]);
            }
        }
    }
}
