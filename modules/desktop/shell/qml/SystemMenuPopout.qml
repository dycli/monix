pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

PopupWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    readonly property bool sleepAllowed: Quickshell.env("KESTREL_ALLOW_SLEEP") === "true"

    function closeAndRun(action): void {
        SystemMenuService.close();
        action();
    }

    color: "transparent"
    width: 205
    height: menu.implicitHeight + 10
    visible: SystemMenuService.isOpen(screenName)
    grabFocus: true

    anchor.item: anchorItem
    anchor.rect.y: anchorItem ? anchorItem.height + Style.popupGap : 0

    onVisibleChanged: {
        if (!visible && SystemMenuService.isOpen(screenName))
            SystemMenuService.close();
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: SystemMenuService.close()
    }

    PopupSurface {
        Column {
            id: menu

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 5
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
