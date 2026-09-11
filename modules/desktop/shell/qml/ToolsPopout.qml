pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

PanelWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    property int popupLeft: 0

    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null

    function closeAndLaunch(command: var): void {
        ToolsMenuService.close();
        LauncherService.launchCommand(command, "normal", "", "");
    }

    color: "transparent"
    implicitWidth: 250
    implicitHeight: menu.implicitHeight + 10
    screen: anchorWindow ? anchorWindow.screen : null
    visible: ToolsMenuService.isOpen(screenName)

    anchors {
        top: true
        left: true
    }
    margins {
        left: popupLeft
        top: Style.popupGap
    }
    exclusiveZone: 0

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "kestrel:popout"
    WlrLayershell.keyboardFocus: root.visible
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    onVisibleChanged: {
        if (visible) {
            if (anchorWindow)
                popupLeft = Math.round(anchorWindow.itemPosition(anchorItem).x);
        } else if (ToolsMenuService.isOpen(screenName)) {
            ToolsMenuService.close();
        }
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
