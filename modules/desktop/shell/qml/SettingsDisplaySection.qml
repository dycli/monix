pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    required property bool panelVisible

    spacing: 8

    onPanelVisibleChanged: {
        if (panelVisible) {
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
        available: BrightnessState.available
        iconAvailable: BrightnessState.available
        icon: BrightnessState.available ? BrightnessState.icon : "󰃠"
        label: "Brightness"
        value: BrightnessState.level
        onMoved: value => BrightnessState.setLevel(value)
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
