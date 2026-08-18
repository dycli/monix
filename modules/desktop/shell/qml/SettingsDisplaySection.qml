pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    spacing: 8

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
        iconAvailable: true
        icon: NightModeState.enabled
            ? "󰖔" : (BrightnessState.available ? BrightnessState.icon : "󰃠")
        label: NightModeState.enabled ? "Brightness · Night light" : "Brightness"
        value: BrightnessState.level
        onIconActivated: NightModeState.toggle()
        onMoved: value => BrightnessState.setLevel(value)
    }
}
