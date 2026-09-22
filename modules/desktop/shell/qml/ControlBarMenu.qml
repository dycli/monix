pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal settingsRequested(string section)
    signal displayRequested

    property bool settingsOpen: false

    height: 24
    spacing: Style.barItemGap

    WifiStatusButton {
        onDetailRequested: root.settingsRequested("network")
    }

    EthernetStatusButton {
        onDetailRequested: root.settingsRequested("network")
    }

    BluetoothStatusButton {
        onDetailRequested: root.settingsRequested("bluetooth")
    }

    BarSlider {
        available: AudioState.available
        icon: AudioState.icon
        iconLeftAligned: true
        value: AudioState.volume / 100
        onIconActivated: {
            if (root.settingsOpen)
                root.settingsRequested("sound");
            else
                AudioState.toggleMute();
        }
        onMoved: value => AudioState.setVolume(value)
        onSecondaryActivated: AudioState.toggleMute()
    }

    BarSlider {
        available: BrightnessState.available
        icon: BrightnessState.internalAvailable ? "󰌢" : "󰍹"
        iconAvailable: true
        iconLeftAligned: true
        value: BrightnessState.level
        onIconActivated: root.displayRequested()
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
        enabled: true
        icon: NightModeState.enabled ? "󰖔" : "󰖨"
        onActivated: {
            if (root.settingsOpen)
                root.displayRequested();
            else
                NightModeState.toggle();
        }
    }
}
