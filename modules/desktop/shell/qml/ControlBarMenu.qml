pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal closeRequested
    signal modeRequested(string mode)

    height: 24
    spacing: 4

    BarModeButton {
        active: NetworkState.connected
        icon: NetworkState.primaryIcon
        interactive: NetworkState.available && (NetworkState.wiredDevice !== null || NetworkState.wifiHardwareEnabled)
        label: NetworkState.primaryLabel
        secondaryInteractive: NetworkState.available
        onActivated: root.modeRequested("network")
        onSecondaryActivated: NetworkState.disablePrimary()
    }

    BarModeButton {
        active: BluetoothState.connected
        interactive: BluetoothState.available
        icon: BluetoothState.icon
        label: BluetoothState.label
        secondaryInteractive: BluetoothState.available
        onActivated: root.modeRequested("bluetooth")
        onSecondaryActivated: BluetoothState.disable()
    }

    BarModeButton {
        active: AudioState.available && !AudioState.muted
        interactive: false
        icon: AudioState.icon
        label: AudioState.label
        secondaryInteractive: AudioState.available
        onSecondaryActivated: AudioState.mute()
    }

    BarModeButton {
        enabled: false
        icon: "󰍹"
        label: "Display"
    }

    SettingsButton {
        anchors.verticalCenter: parent.verticalCenter
        onMenuToggleRequested: root.closeRequested()
    }
}
