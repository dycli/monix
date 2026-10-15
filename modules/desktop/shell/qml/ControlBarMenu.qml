pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal settingsRequested(string section)
    signal displayRequested

    property bool settingsOpen: false
    // A key flashing one control ("volume", "microphone", "brightness")
    // shows that control alone; empty shows them all.
    property string only: ""

    function shows(mode: string): bool {
        return only === "" || only === mode;
    }

    height: 24
    spacing: Style.barItemGap

    WifiStatusButton {
        visible: root.only === "" && NetworkState.wifiDevice !== null
        onDetailRequested: root.settingsRequested("network")
    }

    EthernetStatusButton {
        visible: root.only === "" && NetworkState.wiredDevice !== null
        onDetailRequested: root.settingsRequested("network")
    }

    BluetoothStatusButton {
        visible: root.only === "" && BluetoothState.available
        onDetailRequested: root.settingsRequested("bluetooth")
    }

    BarSlider {
        visible: root.shows("volume")
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

    BarModeButton {
        visible: root.shows("microphone")
        enabled: AudioState.sourceAvailable
        icon: AudioState.sourceIcon
        onActivated: AudioState.toggleSourceMute()
    }

    BarSlider {
        visible: root.shows("brightness")
        available: BrightnessState.available
        icon: BrightnessState.internalAvailable ? "󰌢" : "󰍹"
        iconAvailable: true
        iconLeftAligned: true
        value: BrightnessState.level
        onIconActivated: root.displayRequested()
        onMoved: value => BrightnessState.setLevel(value)
    }

    BarSlider {
        visible: root.only === "" && BrightnessState.internalAvailable
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
        visible: root.only === ""
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
