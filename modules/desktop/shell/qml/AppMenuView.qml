pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Row {
    id: root

    required property var panelWindow

    spacing: Style.barItemGap
    visible: AppMenuService.menus.length > 0

    Repeater {
        model: AppMenuService.menus

        delegate: Text {
            id: menuButton

            required property int index
            required property var modelData

            anchors.verticalCenter: parent.verticalCenter
            color: modelData.enabled ? Style.foregroundColor : Style.panelMutedColor
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: modelData.label

            MouseArea {
                anchors.fill: parent
                cursorShape: menuButton.modelData.enabled
                    ? Qt.PointingHandCursor : Qt.ArrowCursor
                enabled: menuButton.modelData.enabled
                onClicked: AppMenuService.open(menuButton.index)
            }

            PopupWindow {
                id: popup

                property var items: AppMenuService.popupItems
                property var pages: []

                function enter(item): void {
                    pages = pages.concat([{ "label": item.label, "items": items }]);
                    items = item.children;
                }

                function back(): void {
                    if (pages.length === 0)
                        return;
                    const page = pages[pages.length - 1];
                    pages = pages.slice(0, pages.length - 1);
                    items = page.items;
                }

                function closeMenu(): void {
                    if (AppMenuService.activeHeading === menuButton.index)
                        AppMenuService.close();
                }

                anchor.item: menuButton
                anchor.rect.y: menuButton.height
                color: "transparent"
                implicitWidth: 250
                implicitHeight: Math.min(560, menuColumn.implicitHeight + 8)
                grabFocus: true
                visible: AppMenuService.activeHeading === menuButton.index
                    && AppMenuService.popupItems.length > 0

                onVisibleChanged: {
                    if (visible) {
                        items = AppMenuService.popupItems;
                        pages = [];
                    } else {
                        closeMenu();
                    }
                }

                Shortcut {
                    enabled: popup.visible
                    sequence: "Escape"
                    onActivated: popup.pages.length > 0 ? popup.back() : popup.closeMenu()
                }

                PopupSurface {
                    Flickable {
                        anchors {
                            fill: parent
                            margins: 4
                        }
                        contentHeight: menuColumn.implicitHeight
                        clip: true

                        Column {
                            id: menuColumn

                            width: parent.width

                            Rectangle {
                                width: parent.width
                                height: popup.pages.length > 0 ? 28 : 0
                                color: backArea.containsMouse
                                    ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
                                visible: height > 0

                                Text {
                                    anchors {
                                        left: parent.left
                                        leftMargin: 8
                                        verticalCenter: parent.verticalCenter
                                    }
                                    color: Style.foregroundColor
                                    font {
                                        family: Style.fontFamily
                                        pixelSize: Style.textFontSize
                                        weight: Style.fontWeight
                                    }
                                    text: "‹  " + (popup.pages.length > 0
                                        ? popup.pages[popup.pages.length - 1].label : "")
                                }

                                MouseArea {
                                    id: backArea
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    hoverEnabled: true
                                    onClicked: popup.back()
                                }
                            }

                            Repeater {
                                model: popup.items

                                delegate: Item {
                                    id: menuItem

                                    required property var modelData

                                    width: menuColumn.width
                                    height: modelData.separator ? 9 : 28

                                    Rectangle {
                                        anchors {
                                            left: parent.left
                                            right: parent.right
                                            verticalCenter: parent.verticalCenter
                                        }
                                        color: Style.panelBorderColor
                                        height: 1
                                        visible: menuItem.modelData.separator
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        color: itemArea.containsMouse && menuItem.modelData.enabled
                                            ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
                                        visible: !menuItem.modelData.separator
                                    }

                                    Text {
                                        anchors {
                                            left: parent.left
                                            leftMargin: 8
                                            verticalCenter: parent.verticalCenter
                                        }
                                        color: menuItem.modelData.enabled
                                            ? Style.foregroundColor : Style.panelMutedColor
                                        font {
                                            family: Style.fontFamily
                                            pixelSize: Style.textFontSize
                                            weight: Style.fontWeight
                                        }
                                        text: menuItem.modelData.toggle
                                            ? (menuItem.modelData.checked ? "✓  " : "    ")
                                                + menuItem.modelData.label
                                            : menuItem.modelData.label
                                    }

                                    Text {
                                        anchors {
                                            right: parent.right
                                            rightMargin: 8
                                            verticalCenter: parent.verticalCenter
                                        }
                                        color: Style.panelMutedColor
                                        font {
                                            family: Style.fontFamily
                                            pixelSize: Style.textFontSize
                                            weight: Style.fontWeight
                                        }
                                        text: "›"
                                        visible: menuItem.modelData.children
                                            && menuItem.modelData.children.length > 0
                                    }

                                    MouseArea {
                                        id: itemArea
                                        anchors.fill: parent
                                        cursorShape: menuItem.modelData.enabled
                                            ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        enabled: !menuItem.modelData.separator
                                            && menuItem.modelData.enabled
                                        hoverEnabled: true
                                        onClicked: {
                                            if (menuItem.modelData.children
                                                    && menuItem.modelData.children.length > 0) {
                                                popup.enter(menuItem.modelData);
                                            } else {
                                                AppMenuService.activate(menuItem.modelData.id);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
