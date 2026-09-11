pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal systemMenuToggleRequested
    signal findMenuToggleRequested
    signal editMenuToggleRequested
    signal viewMenuToggleRequested
    signal toolsMenuToggleRequested
    signal menuHovered(string menu)

    property alias systemMenuAnchor: systemButton
    property alias findMenuAnchor: findButton
    property alias editMenuAnchor: editButton
    property alias viewMenuAnchor: viewButton
    property alias toolsMenuAnchor: toolsButton

    spacing: Style.barItemGap

    Item {
        id: systemButton

        width: 20
        height: Style.barHeight

        Text {
            anchors.centerIn: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: 16
                weight: Style.fontWeight
            }
            renderType: Text.QtRendering
            rotation: 180
            text: ""
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: root.systemMenuToggleRequested()
            onEntered: root.menuHovered("system")
        }
    }

    Item {
        id: findButton

        width: findLabel.implicitWidth + 8
        height: Style.barHeight

        Text {
            id: findLabel

            anchors.centerIn: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "Find"
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: root.findMenuToggleRequested()
            onEntered: root.menuHovered("find")
        }
    }

    Item {
        id: editButton

        width: editLabel.implicitWidth + 8
        height: Style.barHeight

        Text {
            id: editLabel

            anchors.centerIn: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "Edit"
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: root.editMenuToggleRequested()
            onEntered: root.menuHovered("edit")
        }
    }

    Item {
        id: toolsButton

        width: toolsLabel.implicitWidth + 8
        height: Style.barHeight

        Text {
            id: toolsLabel

            anchors.centerIn: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "Use"
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: root.toolsMenuToggleRequested()
            onEntered: root.menuHovered("tools")
        }
    }

    Item {
        id: viewButton

        width: viewLabel.implicitWidth + 8
        height: Style.barHeight

        Text {
            id: viewLabel

            anchors.centerIn: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "View"
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: root.viewMenuToggleRequested()
            onEntered: root.menuHovered("view")
        }
    }

}
