pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower

Column {
    id: root

    spacing: 8

    Text {
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelTitleFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Power"
    }

    Column {
        width: parent.width
        spacing: 4
        visible: PowerService.hasBattery

        SettingsChoiceButton {
            width: parent.width
            icon: "󰁹"
            interactive: false
            label: PowerService.status
            detail: PowerService.percentage + "% · " + PowerService.time
        }

        SettingsChoiceButton {
            width: parent.width
            icon: "󰂑"
            interactive: false
            label: "Battery health"
            detail: PowerService.health + " · " + PowerService.capacity
        }

        Text {
            color: Style.panelMutedColor
            font {
                family: Style.fontFamily
                pixelSize: Style.smallFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "Power mode"
            visible: PowerService.profilesAvailable
        }

        Row {
            width: parent.width
            spacing: 6
            visible: PowerService.profilesAvailable

            Repeater {
                model: PowerService.availableProfiles

                SettingsChoiceButton {
                    required property var modelData

                    width: (root.width - 12) / PowerService.availableProfiles.length
                    active: PowerProfiles.profile === modelData
                    label: PowerService.profileName(modelData)
                    onActivated: PowerService.setProfile(modelData)
                }
            }
        }

        SettingsChoiceButton {
            width: parent.width
            active: PowerSettingsState.automaticProfile
            icon: "󰑓"
            label: "Automatic profile switching"
            detail: PowerSettingsState.automaticProfile ? "On" : "Off"
            onActivated: PowerSettingsState.toggleAutomaticProfile()
        }

        Text {
            color: Style.panelMutedColor
            font {
                family: Style.fontFamily
                pixelSize: Style.smallFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "On AC power"
        }

        Row {
            width: parent.width
            spacing: 6

            Repeater {
                model: PowerService.availableProfiles

                SettingsChoiceButton {
                    required property var modelData

                    width: (root.width - 12) / PowerService.availableProfiles.length
                    active: PowerSettingsState.acProfile
                        === PowerService.profileKey(modelData)
                    label: PowerService.profileName(modelData)
                    onActivated: PowerSettingsState.setAutomaticProfile(
                        "ac", PowerService.profileKey(modelData))
                }
            }
        }

        Text {
            color: Style.panelMutedColor
            font {
                family: Style.fontFamily
                pixelSize: Style.smallFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "On battery"
        }

        Row {
            width: parent.width
            spacing: 6

            Repeater {
                model: PowerService.availableProfiles

                SettingsChoiceButton {
                    required property var modelData

                    width: (root.width - 12) / PowerService.availableProfiles.length
                    active: PowerSettingsState.batteryProfile
                        === PowerService.profileKey(modelData)
                    label: PowerService.profileName(modelData)
                    onActivated: PowerSettingsState.setAutomaticProfile(
                        "battery", PowerService.profileKey(modelData))
                }
            }
        }
    }

    SettingsChoiceButton {
        width: parent.width
        active: PowerService.idleInhibited
        icon: "󰒳"
        label: "Keep awake"
        detail: PowerService.idleInhibited ? "On" : "Off"
        onActivated: PowerService.idleInhibited = !PowerService.idleInhibited
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.hasBattery && PowerService.profilesAvailable
            ? "Idle policy · " + PowerService.profileName(PowerProfiles.profile)
            : "Idle policy"
    }

    SettingsSlider {
        width: parent.width
        available: PowerSettingsState.currentPolicy.lockEnabled
        iconAvailable: true
        icon: "󰌾"
        label: "Lock automatically"
        value: PowerSettingsState.sliderValue(
            PowerSettingsState.currentPolicy.lockMinutes, 1, 60)
        valueText: PowerSettingsState.currentPolicy.lockEnabled
            ? PowerSettingsState.currentPolicy.lockMinutes + " min" : "Off"
        onIconActivated: PowerSettingsState.togglePolicyField("lockEnabled")
        onMoved: value => PowerSettingsState.setTimeout("lockMinutes", value, 1, 60)
    }

    SettingsSlider {
        width: parent.width
        available: PowerSettingsState.currentPolicy.displayOffEnabled
        iconAvailable: true
        icon: "󰍹"
        label: "Turn displays off"
        value: PowerSettingsState.sliderValue(
            PowerSettingsState.currentPolicy.displayOffMinutes, 1, 60)
        valueText: PowerSettingsState.currentPolicy.displayOffEnabled
            ? PowerSettingsState.currentPolicy.displayOffMinutes + " min" : "Off"
        onIconActivated: PowerSettingsState.togglePolicyField("displayOffEnabled")
        onMoved: value => PowerSettingsState.setTimeout("displayOffMinutes", value, 1, 60)
    }

    SettingsSlider {
        width: parent.width
        available: PowerSettingsState.currentPolicy.suspendEnabled
        iconAvailable: true
        icon: "󰤄"
        label: "Suspend automatically"
        value: PowerSettingsState.sliderValue(
            PowerSettingsState.currentPolicy.suspendMinutes, 5, 120)
        valueText: PowerSettingsState.currentPolicy.suspendEnabled
            ? PowerSettingsState.currentPolicy.suspendMinutes + " min" : "Off"
        onIconActivated: PowerSettingsState.togglePolicyField("suspendEnabled")
        onMoved: value => PowerSettingsState.setTimeout("suspendMinutes", value, 5, 120)
    }
}
