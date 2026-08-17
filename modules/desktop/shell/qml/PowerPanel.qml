pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.UPower

PopupWindow {
    id: root

    required property Item anchorItem
    property bool open: false

    color: "transparent"
    implicitWidth: 360
    implicitHeight: PowerService.hasBattery ? 200 : 120
    grabFocus: true
    visible: open

    onVisibleChanged: if (!visible) open = false

    Shortcut {
        enabled: root.open
        sequence: "S"
        onActivated: PowerService.setProfile(PowerProfile.PowerSaver)
    }

    Shortcut {
        enabled: root.open
        sequence: "B"
        onActivated: PowerService.setProfile(PowerProfile.Balanced)
    }

    Shortcut {
        enabled: root.open && PowerService.availableProfiles.indexOf(PowerProfile.Performance) !== -1
        sequence: "P"
        onActivated: PowerService.setProfile(PowerProfile.Performance)
    }

    Shortcut {
        enabled: root.open
        sequence: "Escape"
        onActivated: root.open = false
    }

    anchor {
        id: popupAnchor

        window: root.anchorItem ? root.anchorItem.QsWindow.window : null
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
            if (!root.anchorItem || !window)
                return;
            const point = window.contentItem.mapFromItem(root.anchorItem,
                root.anchorItem.width - root.implicitWidth, root.anchorItem.height + 6);
            popupAnchor.rect.x = Math.max(8, Math.min(point.x, window.width - root.implicitWidth - 8));
            popupAnchor.rect.y = Math.round(point.y);
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Style.panelColor
        border.color: Style.panelBorderColor
        border.width: 1
        radius: 14

        Column {
            anchors {
                fill: parent
                margins: 16
            }
            spacing: 14

            Row {
                width: parent.width
                height: 36
                spacing: 12

                Item {
                    width: 28
                    height: parent.height

                    BatteryIcon {
                        anchors.centerIn: parent
                        color: PowerService.percentage <= 15 && !PowerService.charging
                            ? Style.lowBatteryColor : Style.foregroundColor
                        percentage: PowerService.percentage
                        charging: PowerService.charging
                        full: PowerService.full
                        visible: PowerService.hasBattery
                    }

                    Text {
                        anchors.fill: parent
                        color: Style.foregroundColor
                        font {
                            family: Style.fontFamily
                            pixelSize: 18
                            weight: Font.Bold
                        }
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        renderType: Text.NativeRendering
                        text: "󰚥"
                        visible: !PowerService.hasBattery
                    }
                }

                Column {
                    width: parent.width - 40
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        color: Style.foregroundColor
                        font: Style.panelTitleFont
                        renderType: Text.NativeRendering
                        text: PowerService.hasBattery
                            ? PowerService.percentage + "%  " + PowerService.status
                            : PowerService.status
                    }

                    Text {
                        color: Style.mutedColor
                        font: Style.panelTextFont
                        renderType: Text.NativeRendering
                        text: PowerService.hasBattery
                            ? PowerService.rate + "   " + (PowerService.charging ? "Until full: " : "Remaining: ") + PowerService.time
                            : "Power profile"
                    }
                }
            }

            Row {
                width: parent.width
                height: 64
                spacing: 10
                visible: PowerService.hasBattery

                Repeater {
                    model: [
                        { "label": "Health", "value": PowerService.health },
                        { "label": "Capacity", "value": PowerService.capacity }
                    ]

                    delegate: Rectangle {
                        required property var modelData

                        width: (parent.width - 10) / 2
                        height: parent.height
                        radius: 10
                        color: Style.panelCardColor

                        Column {
                            anchors.centerIn: parent
                            spacing: 5

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: Style.mutedColor
                                font: Style.panelTextFont
                                renderType: Text.NativeRendering
                                text: modelData.label
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: Style.foregroundColor
                                font: Style.panelValueFont
                                renderType: Text.NativeRendering
                                text: modelData.value
                            }
                        }
                    }
                }
            }

            Row {
                width: parent.width
                height: 38
                spacing: 8

                Repeater {
                    model: PowerService.availableProfiles

                    delegate: Rectangle {
                        id: profileButton

                        required property int modelData
                        readonly property bool active: PowerService.profilesAvailable
                            && PowerProfiles.profile === modelData

                        width: (parent.width - (PowerService.availableProfiles.length - 1) * 8)
                            / PowerService.availableProfiles.length
                        height: parent.height
                        radius: 9
                        color: active ? Style.foregroundColor : Style.panelCardColor

                        Text {
                            anchors.centerIn: parent
                            color: profileButton.active ? Style.panelColor : Style.foregroundColor
                            font: Style.panelTextFont
                            renderType: Text.NativeRendering
                            text: PowerService.profileName(profileButton.modelData)
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            enabled: PowerService.profilesAvailable
                            onClicked: PowerService.setProfile(profileButton.modelData)
                        }
                    }
                }
            }
        }
    }
}
