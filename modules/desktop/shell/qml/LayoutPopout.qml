pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

PanelWindow {
    id: root

    required property string screenName
    required property var targetScreen
    required property int popupLeft
    required property int popupTop

    function setLayout(layout: string): void {
        Hyprland.dispatch("function() hl.config({ general = { layout = "
            + JSON.stringify(layout) + " } }) end");
        ViewMenuService.close();
    }

    color: "transparent"
    implicitWidth: 250
    implicitHeight: menu.implicitHeight + 10
    screen: targetScreen
    visible: ViewMenuService.isOpen(screenName) && ViewMenuService.layoutOpen

    anchors {
        top: true
        left: true
    }
    margins {
        left: popupLeft
        top: popupTop
    }
    exclusiveZone: 0

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "kestrel:popout"
    WlrLayershell.keyboardFocus: root.visible
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: ViewMenuService.close()
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
                label: "Hy3"
                onActivated: root.setLayout("hy3")
            }

            MenuItem {
                width: parent.width
                label: "Scrolling"
                onActivated: root.setLayout("scrolling")
            }

            MenuItem {
                width: parent.width
                label: "Dwindle"
                onActivated: root.setLayout("dwindle")
            }
        }
    }
}
