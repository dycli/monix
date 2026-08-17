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
        implicitHeight: 28
        exclusiveZone: implicitHeight

        anchors {
            top: true
            left: true
            right: true
        }

        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "kestrel:bar"

        Row {
            anchors {
                left: parent.left
                leftMargin: 12
                verticalCenter: parent.verticalCenter
            }

            Workspaces {
                screenName: window.modelData.name
            }
        }

        Row {
            id: rightGroup

            anchors {
                right: parent.right
                rightMargin: 12
                verticalCenter: parent.verticalCenter
            }

            spacing: 6

            Power {}
            SettingsButton {}

            Clock {
                anchors.verticalCenter: parent.verticalCenter
                format: "ddd MMM d  h:mm AP"
            }
        }

    }
}
