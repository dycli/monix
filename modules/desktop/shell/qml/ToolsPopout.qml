pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

PopupWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null

    function closeAndLaunch(command: var): void {
        ToolsMenuService.close();
        LauncherService.launchCommand(command, "normal", "", "");
    }

    color: "transparent"
    width: 300
    height: menu.implicitHeight + 10
    visible: ToolsMenuService.isOpen(screenName)
    grabFocus: false

    anchor.item: anchorItem
    anchor.rect.y: anchorItem ? anchorItem.height + Style.popupGap : 0

    onVisibleChanged: {
        menuGuard.reset();
        if (!visible && ToolsMenuService.isOpen(screenName))
            ToolsMenuService.close();
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: ToolsMenuService.close()
    }

    HyprlandFocusGrab {
        active: root.visible
        windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
        onCleared: ToolsMenuService.close()
    }

    PopupSurface {
        PopupMenuGuard {
            id: menuGuard

            anchors.fill: parent
            onDismissed: ToolsMenuService.close()
        }

        Column {
            id: menu

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 5
            }
            enabled: menuGuard.armed
            spacing: 2

            MenuItem {
                width: parent.width
                label: "Color Picker"
                onActivated: root.closeAndLaunch([
                    Quickshell.env("KESTREL_COLOR_PICKER"), "-a"
                ])
            }

            MenuItem {
                width: parent.width
                label: "Screenshot"
                onActivated: root.closeAndLaunch([
                    Quickshell.env("KESTREL_SCREENSHOT"), "-m", "region"
                ])
            }

            MenuItem {
                width: parent.width
                label: "Calculator"
                onActivated: ToolsMenuService.close()
            }

            MenuItem {
                width: parent.width
                label: "System Monitor"
                onActivated: root.closeAndLaunch([
                    Quickshell.env("KESTREL_TERMINAL"),
                    "-e",
                    Quickshell.env("KESTREL_SYSTEM_MONITOR")
                ])
            }
        }
    }
}
