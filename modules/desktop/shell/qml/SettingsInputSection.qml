pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    spacing: 8

    function rounded(value: real, step: real): real {
        return Math.round(value / step) * step;
    }

    Text {
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelTitleFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Keyboard"
    }

    SettingsSlider {
        width: parent.width
        icon: "󰌌"
        iconAvailable: false
        label: "Repeat rate"
        value: (InputState.repeatRate - 10) / 140
        valueText: InputState.repeatRate + "/s"
        onMoved: value => InputState.setRepeatRate(Math.round(10 + value * 140))
    }

    SettingsSlider {
        width: parent.width
        icon: "󰔛"
        iconAvailable: false
        label: "Repeat delay"
        value: (InputState.repeatDelay - 100) / 900
        valueText: InputState.repeatDelay + " ms"
        onMoved: value => InputState.setRepeatDelay(
            Math.round((100 + value * 900) / 10) * 10)
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Style.panelBorderColor
    }

    Text {
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelTitleFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Pointer"
    }

    SettingsSlider {
        width: parent.width
        icon: "󰍽"
        iconAvailable: false
        label: "Speed"
        value: (InputState.pointerSpeed + 1) / 2
        valueText: (InputState.pointerSpeed > 0 ? "+" : "")
            + InputState.pointerSpeed.toFixed(2)
        onMoved: value => InputState.setPointerSpeed(root.rounded(-1 + value * 2, 0.05))
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Acceleration"
    }

    Row {
        width: parent.width
        spacing: 8

        SettingsChoiceButton {
            width: (parent.width - parent.spacing) / 2
            active: InputState.accelerationProfile === "adaptive"
            label: "Adaptive"
            onActivated: InputState.setAccelerationProfile("adaptive")
        }

        SettingsChoiceButton {
            width: (parent.width - parent.spacing) / 2
            active: InputState.accelerationProfile === "flat"
            label: "Flat"
            onActivated: InputState.setAccelerationProfile("flat")
        }
    }

    SettingsSlider {
        width: parent.width
        icon: "󰕐"
        iconAvailable: false
        label: "Mouse scroll"
        value: (InputState.mouseScrollFactor - 0.25) / 2.75
        valueText: InputState.mouseScrollFactor.toFixed(2) + "×"
        onMoved: value => InputState.setMouseScrollFactor(
            root.rounded(0.25 + value * 2.75, 0.05))
    }

    SettingsSlider {
        width: parent.width
        icon: "󰟸"
        iconAvailable: false
        label: "Touchpad scroll"
        value: (InputState.touchpadScrollFactor - 0.25) / 2.75
        valueText: InputState.touchpadScrollFactor.toFixed(2) + "×"
        onMoved: value => InputState.setTouchpadScrollFactor(
            root.rounded(0.25 + value * 2.75, 0.05))
    }

    Text {
        width: parent.width
        color: Style.lowBatteryColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: InputState.lastError
        visible: InputState.lastError.length > 0
        wrapMode: Text.Wrap
    }
}
