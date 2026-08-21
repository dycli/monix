pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    required property bool panelVisible

    spacing: 8

    onPanelVisibleChanged: {
        if (panelVisible)
            DisplayState.refresh();
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

    Row {
        width: parent.width
        spacing: 8

        SettingsSlider {
            width: parent.width - displayButton.width - parent.spacing
            available: BrightnessState.available
            iconAvailable: true
            icon: NightModeState.enabled
                ? "󰖔" : (BrightnessState.available ? BrightnessState.icon : "󰃠")
            label: NightModeState.enabled ? "Brightness · Night light" : "Brightness"
            value: BrightnessState.level
            onIconActivated: NightModeState.toggle()
            onMoved: value => BrightnessState.setLevel(value)
        }

        Rectangle {
            id: displayButton

            width: 44
            height: 52
            radius: 8
            color: SettingsPanelService.displayExpanded || displayPointer.containsMouse
                ? Qt.rgba(1, 1, 1, SettingsPanelService.displayExpanded ? 0.11 : 0.06)
                : "transparent"

            Text {
                anchors.centerIn: parent
                color: Style.foregroundColor
                font {
                    family: Style.fontFamily
                    pixelSize: 17
                    weight: Style.fontWeight
                }
                renderType: Text.NativeRendering
                text: "󰍹"
            }

            MouseArea {
                id: displayPointer

                anchors.fill: parent
                cursorShape: DisplayState.multipleDisplays
                    ? Qt.PointingHandCursor : Qt.ArrowCursor
                enabled: DisplayState.multipleDisplays
                hoverEnabled: true
                onClicked: {
                    SettingsPanelService.displayExpanded = !SettingsPanelService.displayExpanded;
                    if (SettingsPanelService.displayExpanded)
                        DisplayState.refresh();
                }
            }
        }
    }

    Column {
        width: parent.width
        spacing: 8
        visible: SettingsPanelService.displayExpanded && DisplayState.multipleDisplays

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

        Row {
            width: parent.width
            spacing: 8
            visible: DisplayState.mode === "extend"

            SettingsChoiceButton {
                width: (parent.width - parent.spacing) / 2
                active: DisplayState.side === "left"
                interactive: !DisplayState.busy
                label: "External left"
                onActivated: DisplayState.setSide("left")
            }

            SettingsChoiceButton {
                width: (parent.width - parent.spacing) / 2
                active: DisplayState.side === "right"
                interactive: !DisplayState.busy
                label: "External right"
                onActivated: DisplayState.setSide("right")
            }
        }

        Row {
            width: parent.width
            spacing: 8
            visible: DisplayState.mode === "extend"

            Repeater {
                model: ["top", "center", "bottom"]

                SettingsChoiceButton {
                    required property string modelData

                    width: (root.width - 16) / 3
                    active: DisplayState.alignment === modelData
                    interactive: !DisplayState.busy
                    label: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                    onActivated: DisplayState.setAlignment(modelData)
                }
            }
        }
    }
}
