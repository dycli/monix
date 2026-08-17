pragma ComponentBehavior: Bound

import Quickshell
import QtQuick
import Quickshell.Wayland

Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
        id: window

        required property var modelData

        screen: modelData
        color: "transparent"
        implicitHeight: 32
        exclusiveZone: implicitHeight

        anchors {
            top: true
            left: true
            right: true
        }

        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "kestrel:bar"

        Row {
            id: leftGroup

            anchors {
                left: parent.left
                right: rightGroup.left
                leftMargin: 8
                rightMargin: 16
                verticalCenter: parent.verticalCenter
            }

            spacing: 8

            Workspaces {
                id: workspaces

                screenName: window.modelData.name
            }

            CurrentWindow {
                width: Math.max(0, leftGroup.width - workspaces.width - 8)
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Row {
            id: rightGroup

            anchors {
                right: parent.right
                rightMargin: 8
                verticalCenter: parent.verticalCenter
            }

            spacing: 4

            Power {}
            SettingsButton {}

            Clock {
                anchors.verticalCenter: parent.verticalCenter
                format: "ddd d MMM  HH:mm"
            }
        }

    }
}
