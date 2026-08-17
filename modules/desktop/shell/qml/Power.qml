pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.UPower

Rectangle {
    id: root

    readonly property var batteries: UPower.devices.values.filter(device => device.isLaptopBattery && device.ready)
    readonly property var device: batteries[0] || null
    readonly property int percentage: device ? Math.round(device.percentage * 100) : 0

    width: device ? 58 : 28
    height: 24
    radius: 2
    color: mouse.containsMouse ? "#272a31" : "transparent"

    Row {
        anchors.centerIn: parent
        spacing: 5
        visible: root.device !== null

        Item {
            width: 21
            height: 12
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                id: batteryBody

                width: 18
                height: 10
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                radius: 2
                color: "transparent"
                border {
                    width: 1
                    color: Style.foregroundColor
                }

                Rectangle {
                    anchors {
                        left: parent.left
                        leftMargin: 2
                        verticalCenter: parent.verticalCenter
                    }

                    width: Math.max(1, (batteryBody.width - 4) * root.percentage / 100)
                    height: batteryBody.height - 4
                    radius: 1
                    color: root.percentage <= 15 ? Style.lowBatteryColor : Style.foregroundColor
                }
            }

            Rectangle {
                width: 2
                height: 4
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                radius: 1
                color: Style.foregroundColor
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            color: root.percentage <= 15 ? Style.lowBatteryColor : Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.smallFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: root.percentage + "%"
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

        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: Quickshell.execDetached(["dms", "ipc", "call", "powermenu", "toggle"])
    }
}
