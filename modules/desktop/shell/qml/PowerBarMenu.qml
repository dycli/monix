pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower

Row {
    id: root

    signal closeRequested

    height: 24
    spacing: 10

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.hasBattery
            ? PowerService.percentage + "% " + PowerService.status
            : PowerService.status
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.rate
        visible: PowerService.hasBattery
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.time + (PowerService.charging ? " to full" : " remaining")
        visible: PowerService.hasBattery && !PowerService.full
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Health " + PowerService.health
        visible: PowerService.hasBattery
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.capacity
        visible: PowerService.hasBattery
    }

    Row {
        height: parent.height
        spacing: 4

        Repeater {
            model: PowerService.availableProfiles

            delegate: Item {
                id: profileButton

                required property int modelData
                readonly property bool active: PowerService.profilesAvailable
                    && PowerProfiles.profile === modelData

                width: profileLabel.implicitWidth + 10
                height: parent.height

                Text {
                    id: profileLabel

                    anchors.centerIn: parent
                    color: Style.foregroundColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.textFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: PowerService.profileName(profileButton.modelData)
                }

                Rectangle {
                    width: profileLabel.implicitWidth
                    height: 1
                    anchors {
                        bottom: parent.bottom
                        bottomMargin: 3
                        horizontalCenter: parent.horizontalCenter
                    }
                    color: Style.foregroundColor
                    visible: profileButton.active
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

    Power {
        anchors.verticalCenter: parent.verticalCenter
        onMenuToggleRequested: root.closeRequested()
    }
}
