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

        readonly property int barHeight: 28
        readonly property bool railOverlapsWorkspaces: rightRail.visible
            && rightRail.x < workspaceGroup.x + workspaceGroup.width + Style.barItemGap

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
                leftMargin: 12
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
            visible: !launcher.active && !tickerLane.overlaps(workspaceGroup)
                && !window.railOverlapsWorkspaces

            Workspaces {
                screenName: window.modelData.name
            }
        }

        RightRail {
            id: rightRail

            anchors {
                right: parent.right
                rightMargin: 12
                verticalCenter: parent.verticalCenter
            }
            maximumWidth: Math.max(0, window.width - workspaceGroup.width - 48)
            screenName: window.modelData.name
            visible: !launcher.active
        }

        Item {
            id: tickerLane

            function overlaps(item: Item): bool {
                if (!notificationTicker.visible)
                    return false;

                const contentLeft = x + notificationTicker.contentLeft;
                const contentRight = x + notificationTicker.contentRight;
                return contentLeft < item.x + item.width && contentRight > item.x;
            }

            anchors {
                left: leftRail.right
                leftMargin: Style.barItemGap
                right: rightRail.left
                rightMargin: Style.barItemGap
                top: parent.top
                bottom: parent.bottom
            }
            clip: true
            visible: !launcher.active

            NotificationTicker {
                id: notificationTicker

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
