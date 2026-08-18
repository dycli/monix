pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal modeRequested(string mode)

    readonly property real networkItemX: networkButton.x
    readonly property real bluetoothItemX: bluetoothButton.x

    height: 24
    spacing: Style.rightSectionGap

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
        iconLeftAligned: true
        value: AudioState.volume / 100
        onIconActivated: AudioState.toggleMute()
        onMoved: value => AudioState.setVolume(value)
        onSecondaryActivated: AudioState.toggleMute()
    }

    BarSlider {
        available: BrightnessState.available
        icon: NightModeState.enabled
            ? "󰖔" : (BrightnessState.available ? BrightnessState.icon : "󰃠")
        iconAvailable: true
        value: BrightnessState.level
        onIconActivated: NightModeState.toggle()
        onMoved: value => BrightnessState.setLevel(value)
    }
}
