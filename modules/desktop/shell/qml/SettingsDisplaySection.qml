pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    required property bool panelVisible

    spacing: 8

    onPanelVisibleChanged: {
        if (panelVisible) {
            BrightnessState.refresh();
            DisplayState.refresh();
            NightModeState.refresh();
        }
    }

    Text {
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelTitleFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Display"
    }

    SettingsSlider {
        width: parent.width
        visible: BrightnessState.internalAvailable
        available: BrightnessState.internalAvailable
        iconAvailable: BrightnessState.internalAvailable
        icon: BrightnessState.internalIcon
        label: "Laptop display brightness"
        value: BrightnessState.internalLevel
        onMoved: value => BrightnessState.setInternalLevel(value)
    }

    SettingsSlider {
        width: parent.width
        visible: BrightnessState.externalAvailable
        available: BrightnessState.externalAvailable
        iconAvailable: BrightnessState.externalAvailable
        icon: "󰍹"
        label: DisplayState.externalLabel + " brightness"
        value: BrightnessState.externalLevel
        onMoved: value => BrightnessState.setExternalLevel(value)
    }

    SettingsSlider {
        width: parent.width
        available: true
        iconAvailable: true
        icon: NightModeState.enabled ? "󰖔" : "󰖨"
        label: "Night light strength"
        value: NightModeState.strength
        valueText: NightModeState.enabled
            ? Math.round(NightModeState.strength * 100) + "%" : "Off"
        onIconActivated: NightModeState.toggle()
        onMoved: value => NightModeState.setStrength(value)
    }

    Column {
        width: parent.width
        visible: DisplayState.multipleDisplays

        DisplayControls {
            width: parent.width
        }
    }
}
