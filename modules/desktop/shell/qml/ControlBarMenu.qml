pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

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

    BarSlider {
        available: AudioState.available
        icon: AudioState.icon
        value: AudioState.volume / 100
        onMoved: value => AudioState.setVolume(value)
        onSecondaryActivated: AudioState.mute()
    }

    BarSlider {
        available: BrightnessState.available
        icon: BrightnessState.icon
        value: BrightnessState.level
        onMoved: value => BrightnessState.setLevel(value)
    }
}
