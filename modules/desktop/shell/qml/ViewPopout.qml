pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: root

    required property Item anchorItem
    required property string screenName
    required property var layoutWindow

    property int popupLeft: 0
    readonly property int layoutPopupTop: Style.popupGap + menu.y + layoutItem.y
    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null

    function run(command: var): void {
        ViewMenuService.close();
        hyprlandCommand.command = command;
        hyprlandCommand.running = true;
    }

    color: "transparent"
    implicitWidth: 250
    implicitHeight: menu.implicitHeight + 10
    screen: anchorWindow ? anchorWindow.screen : null
    visible: ViewMenuService.isOpen(screenName)

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
        } else if (ViewMenuService.isOpen(screenName)) {
            ViewMenuService.close();
        }
    }

    Process {
        id: hyprlandCommand
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: ViewMenuService.close()
    }

    HyprlandFocusGrab {
        active: root.visible
        windows: root.anchorWindow
            ? [root, root.layoutWindow, root.anchorWindow]
            : [root, root.layoutWindow]
        onCleared: ViewMenuService.close()
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
                label: "Float All"
                onHoveredChanged: if (hovered) ViewMenuService.hideLayout()
                onActivated: root.run([
                    "hyprctl", "dispatch", "workspaceopt", "allfloat"
                ])
            }

            MenuItem {
                id: layoutItem

                width: parent.width
                label: "Layout"
                detail: "›"
                onHoveredChanged: if (hovered) ViewMenuService.showLayout(root.screenName)
                onActivated: ViewMenuService.showLayout(root.screenName)
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Style.panelBorderColor
            }

            MenuItem {
                width: parent.width
                label: "Overview"
                onHoveredChanged: if (hovered) ViewMenuService.hideLayout()
                onActivated: ViewMenuService.close()
            }

            MenuItem {
                width: parent.width
                label: "Magic Workspace"
                onHoveredChanged: if (hovered) ViewMenuService.hideLayout()
                onActivated: root.run([
                    "hyprctl", "eval",
                    "hl.dispatch(hl.dsp.workspace.toggle_special('magic'))"
                ])
            }
        }
    }
}
