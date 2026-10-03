pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    property bool deviceSelectorOpen: false

    spacing: 8

    Component.onCompleted: InputState.refreshDevices()

    function deviceLabel(name: string): string {
        if (!name)
            return "All pointers";
        const words = name.replace(/-/g, " ");
        return words.charAt(0).toUpperCase() + words.slice(1);
    }

    function deviceDetail(name: string): string {
        if (!name)
            return "";
        if (!InputState.connectedDevices.includes(name))
            return "Not connected";
        return InputState.deviceOverrides[name] ? "Custom" : "";
    }

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

    SettingsChoiceButton {
        width: parent.width
        icon: "󰍽"
        label: root.deviceLabel(InputState.selectedDevice)
        detail: root.deviceSelectorOpen ? "" : ""
        onActivated: {
            root.deviceSelectorOpen = !root.deviceSelectorOpen;
            if (root.deviceSelectorOpen)
                InputState.refreshDevices();
        }
    }

    Repeater {
        model: root.deviceSelectorOpen ? [""].concat(InputState.knownDevices) : []

        delegate: SettingsChoiceButton {
            required property string modelData

            width: root.width
            active: modelData === InputState.selectedDevice
            label: root.deviceLabel(modelData)
            detail: root.deviceDetail(modelData)
            onActivated: {
                InputState.selectDevice(modelData);
                root.deviceSelectorOpen = false;
            }
        }
    }

    SettingsSlider {
        width: parent.width
        icon: "󰍽"
        iconAvailable: false
        label: "Speed"
        value: (InputState.selectedPointerSpeed + 1) / 2
        valueText: (InputState.selectedPointerSpeed > 0 ? "+" : "")
            + InputState.selectedPointerSpeed.toFixed(2)
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
            active: InputState.selectedAccelerationProfile === "adaptive"
            label: "Adaptive"
            onActivated: InputState.setAccelerationProfile("adaptive")
        }

        SettingsChoiceButton {
            width: (parent.width - parent.spacing) / 2
            active: InputState.selectedAccelerationProfile === "flat"
            label: "Flat"
            onActivated: InputState.setAccelerationProfile("flat")
        }
    }

    SettingsSlider {
        width: parent.width
        icon: "󰕐"
        iconAvailable: false
        label: InputState.selectedDevice ? "Scroll" : "Mouse scroll"
        value: (InputState.selectedScrollFactor - 0.25) / 2.75
        valueText: InputState.selectedScrollFactor.toFixed(2) + "×"
        onMoved: value => InputState.setScrollFactor(
            root.rounded(0.25 + value * 2.75, 0.05))
    }

    SettingsSlider {
        width: parent.width
        visible: !InputState.selectedDevice
        icon: "󰟸"
        iconAvailable: false
        label: "Touchpad scroll"
        value: (InputState.touchpadScrollFactor - 0.25) / 2.75
        valueText: InputState.touchpadScrollFactor.toFixed(2) + "×"
        onMoved: value => InputState.setTouchpadScrollFactor(
            root.rounded(0.25 + value * 2.75, 0.05))
    }

    SettingsChoiceButton {
        width: parent.width
        visible: InputState.selectedOverride !== null
        icon: "󰑓"
        label: "Use default pointer settings"
        onActivated: InputState.resetDevice(InputState.selectedDevice)
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
