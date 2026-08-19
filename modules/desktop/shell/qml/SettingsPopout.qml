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
    readonly property real desiredHeight: content.implicitHeight + 76
    readonly property real maximumHeight: Math.max(320, screenHeight - 52)

    color: "transparent"
    implicitWidth: 520
    implicitHeight: Math.min(desiredHeight, maximumHeight)
    grabFocus: true
    visible: SettingsPanelService.isOpen(screenName)

    onVisibleChanged: {
        if (!visible && SettingsPanelService.isOpen(screenName))
            SettingsPanelService.close();
    }

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
            const point = window.contentItem.mapFromItem(root.anchorItem,
                root.anchorItem.width - root.implicitWidth, root.anchorItem.height + 6);
            popupAnchor.rect.x = Math.max(8,
                Math.min(point.x, window.width - root.implicitWidth - 8));
            popupAnchor.rect.y = Math.round(point.y);
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Style.popupBackgroundColor
        border.color: Style.panelBorderColor
        border.width: 1
        radius: 12

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

            Flickable {
                id: scroll

                anchors {
                    left: parent.left
                    right: parent.right
                    top: header.bottom
                    topMargin: 10
                    bottom: parent.bottom
                }
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                contentWidth: width
                contentHeight: content.implicitHeight

                Column {
                    id: content

                    width: scroll.width
                    spacing: 18

                    SettingsNetworkSection {
                        id: networkSection

                        width: parent.width
                        panelVisible: root.visible
                        visible: NetworkState.available
                            && (NetworkState.wiredDevice !== null
                                || NetworkState.wifiDevice !== null)
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Style.panelBorderColor
                        visible: networkSection.visible && bluetoothSection.visible
                    }

                    SettingsBluetoothSection {
                        id: bluetoothSection

                        width: parent.width
                        panelVisible: root.visible
                        visible: BluetoothState.available
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Style.panelBorderColor
                        visible: networkSection.visible || bluetoothSection.visible
                    }

                    SettingsAudioSection {
                        width: parent.width
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Style.panelBorderColor
                    }

                    SettingsDisplaySection {
                        width: parent.width
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Style.panelBorderColor
                    }

                    SettingsInputSection {
                        width: parent.width
                    }
                }
            }
        }
    }
}
