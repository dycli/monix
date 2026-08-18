pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets

Item {
    id: root

    readonly property real itemSize: 16
    readonly property real itemGap: 12

    implicitWidth: trayRow.implicitWidth
    implicitHeight: 24
    width: implicitWidth
    height: implicitHeight
    visible: width > 0

    Row {
        id: trayRow

        anchors.verticalCenter: parent.verticalCenter
        spacing: root.itemGap

        Repeater {
            model: SystemTray.items

            delegate: MouseArea {
                id: trayItem

                required property SystemTrayItem modelData

                width: root.itemSize
                height: 24
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor

                onClicked: event => {
                    if (event.button === Qt.MiddleButton) {
                        modelData.secondaryActivate();
                    } else if (event.button === Qt.RightButton) {
                        if (modelData.hasMenu)
                            menu.open();
                    } else if (modelData.onlyMenu && modelData.hasMenu) {
                        menu.open();
                    } else {
                        modelData.activate();
                    }
                }

                onWheel: event => {
                    const horizontal = Math.abs(event.angleDelta.x) > Math.abs(event.angleDelta.y);
                    modelData.scroll(horizontal ? event.angleDelta.x : event.angleDelta.y,
                        horizontal);
                }

                QsMenuAnchor {
                    id: menu

                    menu: trayItem.modelData.menu
                    anchor {
                        item: trayItem
                        adjustment: PopupAdjustment.Slide
                        edges: Edges.Bottom | Edges.Left
                        gravity: Edges.Bottom | Edges.Right
                    }
                }

                IconImage {
                    id: icon

                    anchors.centerIn: parent
                    width: root.itemSize
                    height: root.itemSize
                    source: trayItem.modelData.icon
                    asynchronous: true
                    smooth: true
                    mipmap: true
                    visible: status === Image.Ready
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        saturation: -1
                        colorization: 1
                        colorizationColor: Style.foregroundColor
                    }
                }

                Text {
                    anchors.centerIn: parent
                    color: Style.foregroundColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.smallFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: {
                        const title = trayItem.modelData.title || trayItem.modelData.id || "?";
                        return title.slice(0, 1).toUpperCase();
                    }
                    visible: !icon.visible
                }
            }
        }
    }
}
