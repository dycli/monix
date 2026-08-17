pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal modeRequested(string mode)

    readonly property real networkItemX: networkButton.x
    readonly property real bluetoothItemX: bluetoothButton.x

    height: 24
    spacing: 4

    NetworkStatusButton {
        id: networkButton

        onDetailRequested: root.modeRequested("network")
    }

    BluetoothStatusButton {
        id: bluetoothButton

        onDetailRequested: root.modeRequested("bluetooth")
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
