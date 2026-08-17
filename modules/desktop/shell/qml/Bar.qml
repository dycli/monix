pragma ComponentBehavior: Bound

import Quickshell
import QtQuick
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

        IdleInhibitor {
            window: window
            enabled: PowerService.idleInhibited
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

            Power {
                scaleFactor: window.scaleFactor
            }
            SettingsButton {
                scaleFactor: window.scaleFactor
            }

            Clock {
                anchors.verticalCenter: parent.verticalCenter
                fontPixelSize: window.barFontSize
                format: "ddd MMM d h:mm AP"
            }
        }

    }
}
