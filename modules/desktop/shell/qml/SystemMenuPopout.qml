pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

PanelWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
    readonly property bool sleepAllowed: Quickshell.env("KESTREL_ALLOW_SLEEP") === "true"

    function closeAndRun(action): void {
        SystemMenuService.close();
        action();
    }

    color: "transparent"
    implicitWidth: 238
    implicitHeight: menu.implicitHeight + 12
    screen: anchorWindow ? anchorWindow.screen : null
    visible: SystemMenuService.isOpen(screenName)

    anchors {
        top: true
        left: true
    }
    margins.left: anchorItem ? Math.round(anchorItem.mapToItem(null, 0, 0).x) : 0
    exclusiveZone: 0

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "kestrel:popout"
    WlrLayershell.keyboardFocus: root.visible
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    onVisibleChanged: {
        if (!visible && SystemMenuService.isOpen(screenName))
            SystemMenuService.close();
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: SystemMenuService.close()
    }

    HyprlandFocusGrab {
        active: root.visible
        windows: [root]
        onCleared: SystemMenuService.close()
    }

    PopupSurface {
        Column {
            id: menu

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 6
            }
            spacing: 2

            MenuItem {
                width: parent.width
                label: "About This Kestrel"
                onActivated: root.closeAndRun(() => LauncherService.launchCommand([
                    Quickshell.env("KESTREL_TERMINAL"),
                    "--class=com.mitchellh.ghostty.floating",
                    "--wait-after-command=true",
                    "-e",
                    Quickshell.env("KESTREL_MICROFETCH")
                ], "normal", "", ""))
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Style.panelBorderColor
            }

            MenuItem {
                width: parent.width
                label: "System Settings…"
                onActivated: root.closeAndRun(() => SettingsPanelService.toggle(root.screenName))
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Style.panelBorderColor
            }

            MenuItem {
                width: parent.width
                label: "Sleep"
                visible: root.sleepAllowed
                onActivated: root.closeAndRun(() => SessionService.suspend())
            }

            MenuItem {
                width: parent.width
                label: "Restart"
                onActivated: root.closeAndRun(() => SessionService.reboot())
            }

            MenuItem {
                width: parent.width
                label: "Shut Down"
                onActivated: root.closeAndRun(() => SessionService.powerOff())
            }

            MenuItem {
                width: parent.width
                label: "Lock Screen"
                onActivated: root.closeAndRun(() => SessionService.lock())
            }

            MenuItem {
                width: parent.width
                label: "Log Out"
                onActivated: root.closeAndRun(() => SessionService.logout())
            }
        }
    }
}
