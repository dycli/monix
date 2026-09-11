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

        readonly property int barHeight: Style.barHeight
        readonly property bool menuBarOpen: SystemMenuService.isOpen(modelData.name)
            || LauncherService.isOpen(modelData.name)
            || ClipboardPanelService.isOpen(modelData.name)
            || ViewMenuService.isOpen(modelData.name)
            || ToolsMenuService.isOpen(modelData.name)
        readonly property bool railOverlapsWorkspaces: rightRail.visible
            && rightRail.x < workspaceGroup.x + workspaceGroup.width + Style.barItemGap

        function switchMenu(menu: string): void {
            if (!window.menuBarOpen
                    || (menu === "system" && SystemMenuService.isOpen(window.modelData.name))
                    || (menu === "find" && LauncherService.isOpen(window.modelData.name))
                    || (menu === "edit" && ClipboardPanelService.isOpen(window.modelData.name))
                    || (menu === "view" && ViewMenuService.isOpen(window.modelData.name))
                    || (menu === "tools" && ToolsMenuService.isOpen(window.modelData.name)))
                return;

            SystemMenuService.close();
            LauncherService.close();
            ClipboardPanelService.close();
            ViewMenuService.close();
            ToolsMenuService.close();

            switch (menu) {
            case "system":
                SystemMenuService.toggle(window.modelData.name);
                break;
            case "find":
                LauncherService.open(window.modelData.name);
                break;
            case "edit":
                ClipboardPanelService.toggle(window.modelData.name);
                break;
            case "view":
                ViewMenuService.toggle(window.modelData.name);
                break;
            case "tools":
                ToolsMenuService.toggle(window.modelData.name);
                break;
            }
        }

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
            enabled: BarModeService.isActive(window.modelData.name)
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            onTapped: eventPoint => {
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
            onSystemMenuToggleRequested: {
                BarModeService.close();
                ClockPanelService.close();
                ClipboardPanelService.close();
                SettingsPanelService.close();
                LauncherService.close();
                ViewMenuService.close();
                ToolsMenuService.close();
                SystemMenuService.toggle(window.modelData.name);
            }
            onFindMenuToggleRequested: {
                SystemMenuService.close();
                ClipboardPanelService.close();
                SettingsPanelService.close();
                ClockPanelService.close();
                BarModeService.close();
                ViewMenuService.close();
                ToolsMenuService.close();
                LauncherService.toggle(window.modelData.name);
            }
            onEditMenuToggleRequested: {
                SystemMenuService.close();
                LauncherService.close();
                SettingsPanelService.close();
                ClockPanelService.close();
                BarModeService.close();
                ViewMenuService.close();
                ToolsMenuService.close();
                ClipboardPanelService.toggle(window.modelData.name);
            }
            onViewMenuToggleRequested: {
                SystemMenuService.close();
                LauncherService.close();
                ClipboardPanelService.close();
                SettingsPanelService.close();
                ClockPanelService.close();
                BarModeService.close();
                ToolsMenuService.close();
                ViewMenuService.toggle(window.modelData.name);
            }
            onToolsMenuToggleRequested: {
                SystemMenuService.close();
                LauncherService.close();
                ClipboardPanelService.close();
                SettingsPanelService.close();
                ClockPanelService.close();
                BarModeService.close();
                ViewMenuService.close();
                ToolsMenuService.toggle(window.modelData.name);
            }
            onMenuHovered: menu => window.switchMenu(menu)
        }

        SystemMenuPopout {
            anchorItem: leftRail.systemMenuAnchor
            screenName: window.modelData.name
        }

        FindPopout {
            anchorItem: leftRail.findMenuAnchor
            screenName: window.modelData.name
        }

        EditPopout {
            id: editPopout

            anchorItem: leftRail.editMenuAnchor
            emojiWindow: emojiPopout
            screenName: window.modelData.name
        }

        EmojiPopout {
            id: emojiPopout

            popupLeft: editPopout.popupLeft + editPopout.implicitWidth + Style.popupGap
            popupTop: editPopout.emojiPopupTop
            screenName: window.modelData.name
            targetScreen: window.modelData
        }

        ViewPopout {
            id: viewPopout

            anchorItem: leftRail.viewMenuAnchor
            layoutWindow: layoutPopout
            screenName: window.modelData.name
        }

        LayoutPopout {
            id: layoutPopout

            popupLeft: viewPopout.popupLeft + viewPopout.implicitWidth + Style.popupGap
            popupTop: viewPopout.layoutPopupTop
            screenName: window.modelData.name
            targetScreen: window.modelData
        }

        ToolsPopout {
            anchorItem: leftRail.toolsMenuAnchor
            screenName: window.modelData.name
        }

        Row {
            id: workspaceGroup

            anchors {
                horizontalCenter: parent.horizontalCenter
                verticalCenter: parent.verticalCenter
            }
            visible: !tickerLane.overlaps(workspaceGroup) && !window.railOverlapsWorkspaces

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

            NotificationTicker {
                id: notificationTicker

                anchors.fill: parent
                screenName: window.modelData.name
            }
        }

    }
}
