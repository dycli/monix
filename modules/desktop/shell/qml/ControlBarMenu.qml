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
        onActivated: root.modeRequested("network")
    }

    BarModeButton {
        active: BluetoothState.connected
        interactive: false
        icon: BluetoothState.icon
        label: BluetoothState.label
    }

    BarModeButton {
        active: AudioState.available && !AudioState.muted
        interactive: false
        icon: AudioState.icon
        label: AudioState.label
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
