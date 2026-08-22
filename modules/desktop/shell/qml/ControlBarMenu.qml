pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal settingsRequested(string section)
    signal displayRequested

    height: 24
    spacing: Style.barItemGap

    WifiStatusButton {
        onDetailRequested: root.settingsRequested("network")
    }

    EthernetStatusButton {
        onDetailRequested: root.settingsRequested("network")
    }

    BluetoothStatusButton {
        id: bluetoothButton

        onDetailRequested: root.settingsRequested("bluetooth")
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
        iconLeftAligned: true
        value: BrightnessState.level
        onIconActivated: NightModeState.toggle()
        onMoved: value => BrightnessState.setLevel(value)
    }

    BarSlider {
        visible: BrightnessState.internalAvailable
            && BrightnessState.externalAvailable
        available: BrightnessState.externalAvailable
        icon: "󰍹"
        iconAvailable: true
        iconLeftAligned: true
        value: BrightnessState.externalLevel
        onIconActivated: root.displayRequested()
        onMoved: value => BrightnessState.setExternalLevel(value)
    }

    BarModeButton {
        enabled: DisplayState.multipleDisplays
        icon: "󰍺"
        onActivated: root.displayRequested()
    }
}
