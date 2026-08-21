pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    spacing: 8

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: DisplayState.internalLabel + " · " + DisplayState.externalLabel
    }

    Grid {
        width: parent.width
        columns: 2
        columnSpacing: 8
        rowSpacing: 8

        Repeater {
            model: [
                { "mode": "extend", "icon": "󰍹", "label": "Extend" },
                { "mode": "mirror", "icon": "󰹑", "label": "Mirror" },
                { "mode": "internal", "icon": "󰌢", "label": "Laptop only" },
                { "mode": "external", "icon": "󰍺", "label": "External only" }
            ]

            SettingsChoiceButton {
                required property var modelData

                width: (root.width - 8) / 2
                active: DisplayState.mode === modelData.mode
                icon: modelData.icon
                interactive: !DisplayState.busy
                label: modelData.label
                onActivated: DisplayState.setMode(modelData.mode)
            }
        }
    }

    DisplayLayoutPreview {
        width: parent.width
        visible: DisplayState.mode === "extend"
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
        text: DisplayState.lastError
        visible: DisplayState.lastError.length > 0
        wrapMode: Text.Wrap
    }
}
