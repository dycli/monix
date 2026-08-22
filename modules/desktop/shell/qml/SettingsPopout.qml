pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

PopupWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
    readonly property real screenHeight: anchorWindow && anchorWindow.screen
        ? anchorWindow.screen.height : 692
    readonly property real maximumHeight: Math.max(320, screenHeight
        - Style.barHeight - Style.popupBarGap - Style.popupScreenMargin)
    readonly property var sections: {
        const available = [];
        if (NetworkState.available
                && (NetworkState.wiredDevice !== null || NetworkState.wifiDevice !== null))
            available.push({ "key": "network", "icon": "󰖩", "label": "Network" });
        if (BluetoothState.available)
            available.push({ "key": "bluetooth", "icon": "󰂯", "label": "Bluetooth" });
        available.push(
            { "key": "sound", "icon": "", "label": "Sound" },
            { "key": "display", "icon": "󰍹", "label": "Display" },
            { "key": "input", "icon": "󰌌", "label": "Input" },
            { "key": "power", "icon": "󰐥", "label": "Power" }
        );
        return available;
    }

    function ensureSection(): void {
        if (!sections.some(section => section.key === SettingsPanelService.section))
            SettingsPanelService.section = sections.length > 0 ? sections[0].key : "sound";
    }

    color: "transparent"
    implicitWidth: 720
    implicitHeight: Math.min(680, maximumHeight)
    grabFocus: true
    visible: SettingsPanelService.isOpen(screenName)
    mask: Region {
        width: root.width
        height: root.height
        radius: Style.popupRadius
    }
    onVisibleChanged: {
        if (visible)
            ensureSection();
        else if (SettingsPanelService.isOpen(screenName))
            SettingsPanelService.close();
    }

    onSectionsChanged: ensureSection()

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: SettingsPanelService.close()
    }

    anchor {
        id: popupAnchor

        window: root.anchorItem ? root.anchorItem.QsWindow.window : null
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
            if (!root.anchorItem || !window)
                return;
            popupAnchor.rect.x = Math.round(window.width - root.implicitWidth
                - Style.popupScreenMargin);
            popupAnchor.rect.y = window.height + Style.popupBarGap;
        }
    }

    PopupSurface {

        Item {
            anchors {
                fill: parent
                margins: 18
            }

            Item {
                id: header

                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                }
                height: 30

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    color: Style.foregroundColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.panelTitleFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: "Settings"
                }

                Text {
                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                    }
                    color: Style.panelMutedColor
                    font {
                        family: Style.fontFamily
                        pixelSize: 14
                        weight: Style.fontWeight
                    }
                    text: "×"

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8
                        cursorShape: Qt.PointingHandCursor
                        onClicked: SettingsPanelService.close()
                    }
                }
            }

            Item {
                anchors {
                    left: parent.left
                    right: parent.right
                    top: header.bottom
                    topMargin: 10
                    bottom: parent.bottom
                }

                Item {
                    id: navigation

                    anchors {
                        left: parent.left
                        top: parent.top
                        bottom: parent.bottom
                    }
                    width: 154

                    Column {
                        width: parent.width
                        spacing: 4

                        Repeater {
                            model: root.sections

                            SettingsChoiceButton {
                                required property var modelData

                                width: navigation.width
                                active: SettingsPanelService.section === modelData.key
                                icon: modelData.icon
                                label: modelData.label
                                onActivated: SettingsPanelService.section = modelData.key
                            }
                        }
                    }
                }

                Rectangle {
                    id: navigationDivider

                    anchors {
                        left: navigation.right
                        leftMargin: 14
                        top: parent.top
                        bottom: parent.bottom
                    }
                    width: 1
                    color: Style.panelBorderColor
                }

                Flickable {
                    id: pageScroll

                    anchors {
                        left: navigationDivider.right
                        leftMargin: 18
                        right: parent.right
                        top: parent.top
                        bottom: parent.bottom
                    }
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    contentWidth: width
                    contentHeight: pageLoader.height

                    Loader {
                        id: pageLoader

                        width: pageScroll.width
                        height: item ? item.implicitHeight : 0
                        onSourceComponentChanged: pageScroll.contentY = 0
                        sourceComponent: {
                            switch (SettingsPanelService.section) {
                            case "network": return networkPage;
                            case "bluetooth": return bluetoothPage;
                            case "sound": return soundPage;
                            case "display": return displayPage;
                            case "input": return inputPage;
                            case "power": return powerPage;
                            default: return soundPage;
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: networkPage

        SettingsNetworkSection {
            width: pageLoader.width
            panelVisible: root.visible && SettingsPanelService.section === "network"
        }
    }

    Component {
        id: bluetoothPage

        SettingsBluetoothSection {
            width: pageLoader.width
            panelVisible: root.visible && SettingsPanelService.section === "bluetooth"
        }
    }

    Component {
        id: soundPage

        SettingsAudioSection {
            width: pageLoader.width
        }
    }

    Component {
        id: displayPage

        SettingsDisplaySection {
            width: pageLoader.width
            panelVisible: root.visible && SettingsPanelService.section === "display"
        }
    }

    Component {
        id: inputPage

        SettingsInputSection {
            width: pageLoader.width
        }
    }

    Component {
        id: powerPage

        SettingsPowerSection {
            width: pageLoader.width
        }
    }
}
