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
        WlrLayershell.keyboardFocus: BarModeService.wantsKeyboard
            && BarModeService.isActive(window.modelData.name)
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

        TapHandler {
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            onTapped: eventPoint => {
                if (!BarModeService.isActive(window.modelData.name))
                    return;
                if (launcher.active) {
                    const launcherPoint = launcher.mapFromItem(window.contentItem,
                        eventPoint.position.x, eventPoint.position.y);
                    if (launcher.contains(launcherPoint))
                        return;
                }
                const point = rightRail.mapFromItem(window.contentItem,
                    eventPoint.position.x, eventPoint.position.y);
                if (!rightRail.contains(point))
                    BarModeService.close();
            }
        }

        LeftRail {
            id: leftRail

            anchors {
                left: parent.left
                leftMargin: Math.round(12 * window.scaleFactor)
                verticalCenter: parent.verticalCenter
            }
            visible: !launcher.active
        }

        Row {
            id: workspaceGroup

            anchors {
                horizontalCenter: parent.horizontalCenter
                verticalCenter: parent.verticalCenter
            }
            visible: !launcher.active

            Workspaces {
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
            maximumWidth: Math.max(0, window.width - workspaceGroup.width - 48)
            screenName: window.modelData.name
            visible: !launcher.active
        }

        Item {
            id: tickerLane

            anchors {
                left: workspaceGroup.right
                leftMargin: 12
                right: rightRail.left
                rightMargin: 12
                top: parent.top
                bottom: parent.bottom
            }
            clip: true
            visible: !launcher.active

            NotificationTicker {
                anchors.fill: parent
                screenName: window.modelData.name
            }
        }

        Launcher {
            id: launcher

            anchors {
                left: parent.left
                leftMargin: 12
                right: parent.right
                rightMargin: 12
                top: parent.top
                bottom: parent.bottom
            }
            screenName: window.modelData.name
        }

    }
}
