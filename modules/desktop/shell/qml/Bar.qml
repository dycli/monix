pragma ComponentBehavior: Bound

import Quickshell
import QtQuick
import Quickshell.Hyprland
import Quickshell.Wayland

Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
        id: window

        required property var modelData

        readonly property real scaleFactor: 1
        readonly property int barHeight: 28
        readonly property int barFontSize: 10

        screen: modelData
        color: "transparent"
        implicitHeight: barHeight
        exclusiveZone: implicitHeight

        anchors {
            top: true
            left: true
            right: true
        }

        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "kestrel:bar"
        WlrLayershell.keyboardFocus: BarModeService.wantsKeyboard && modeHost.active
            ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        IdleInhibitor {
            window: window
            enabled: PowerService.idleInhibited
        }

        HyprlandFocusGrab {
            active: modeHost.active
            windows: [window]
            onCleared: BarModeService.close()
        }

        Row {
            id: leftGroup

            anchors {
                left: parent.left
                leftMargin: Math.round(12 * window.scaleFactor)
                verticalCenter: parent.verticalCenter
            }

            Workspaces {
                fontPixelSize: window.barFontSize
                scaleFactor: window.scaleFactor
                screenName: window.modelData.name
            }
        }

        Row {
            id: rightGroup

            anchors {
                right: parent.right
                rightMargin: Math.round(12 * window.scaleFactor)
                verticalCenter: parent.verticalCenter
            }

            spacing: Math.round(10 * window.scaleFactor)
            visible: !modeHost.active

            Power {
                scaleFactor: window.scaleFactor
                onMenuToggleRequested: BarModeService.toggle("power", window.modelData.name)
            }
            SettingsButton {
                scaleFactor: window.scaleFactor
                onMenuToggleRequested: BarModeService.toggle("control", window.modelData.name)
            }

            Clock {
                id: clock

                anchors.verticalCenter: parent.verticalCenter
                fontPixelSize: window.barFontSize
                format: "ddd MMM d h:mm AP"
                onClicked: {
                    BarModeService.close();
                    ClockPanelService.toggle(window.modelData.name);
                }
            }
        }

        Item {
            id: tickerLane

            anchors {
                left: leftGroup.right
                leftMargin: 12
                right: modeHost.active ? modeHost.left : rightGroup.left
                rightMargin: 12
                top: parent.top
                bottom: parent.bottom
            }
            clip: true

            NotificationTicker {
                anchors.fill: parent
                screenName: window.modelData.name
            }
        }

        ClockPopout {
            anchorItem: clock
            screenName: window.modelData.name
        }

        BarModeHost {
            id: modeHost

            anchors {
                right: parent.right
                rightMargin: 12
                verticalCenter: parent.verticalCenter
            }
            screenName: window.modelData.name
        }

    }
}
