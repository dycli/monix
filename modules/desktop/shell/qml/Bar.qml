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
        WlrLayershell.keyboardFocus: BarModeService.wantsKeyboard && rightRail.pinned
            ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        IdleInhibitor {
            window: window
            enabled: PowerService.idleInhibited
        }

        HyprlandFocusGrab {
            active: rightRail.pinned
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

        RightRail {
            id: rightRail

            anchors {
                right: parent.right
                rightMargin: Math.round(12 * window.scaleFactor)
                verticalCenter: parent.verticalCenter
            }
            maximumWidth: Math.max(0, window.width - leftGroup.width - 48)
            screenName: window.modelData.name
        }

        Item {
            id: tickerLane

            anchors {
                left: leftGroup.right
                leftMargin: 12
                right: rightRail.left
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

    }
}
