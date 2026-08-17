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
                anchors.verticalCenter: parent.verticalCenter
                fontPixelSize: window.barFontSize
                format: "ddd MMM d h:mm AP"
            }
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
