pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Row {
    id: root

    signal systemMenuToggleRequested
    signal findMenuToggleRequested
    signal editMenuToggleRequested
    signal toolsMenuToggleRequested
    signal menuHovered(string menu)

    property alias systemMenuAnchor: systemButton
    property alias findMenuAnchor: findButton
    property alias editMenuAnchor: editButton
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
            text: "Tools"
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: root.toolsMenuToggleRequested()
            onEntered: root.menuHovered("tools")
        }
    }

    Repeater {
        model: [
            {
                label: "Web",
                command: [Quickshell.env("KESTREL_BROWSER"), "--new-window", "--ozone-platform=wayland"],
                startupClass: "brave-browser"
            },
            {
                label: "Terminal",
                command: [Quickshell.env("KESTREL_TERMINAL")],
                startupClass: "com.mitchellh.ghostty"
            }
        ]

        delegate: Text {
            id: appButton

            required property var modelData

            anchors.verticalCenter: parent.verticalCenter
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: modelData.label

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: event => {
                    const mode = event.button === Qt.RightButton
                        ? "floating" : (event.button === Qt.MiddleButton
                            ? "workspace" : "normal");
                    LauncherService.launchCommand(appButton.modelData.command, mode, "",
                        appButton.modelData.startupClass);
                }
            }
        }
    }
}
