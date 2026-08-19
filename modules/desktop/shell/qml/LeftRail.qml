pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Row {
    id: root

    signal homeActivated

    spacing: Style.barItemGap

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.iconFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: ""

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.homeActivated()
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
            },
            {
                label: "Email",
                command: [Quickshell.env("KESTREL_EMAIL")],
                startupClass: "thunderbird"
            },
            {
                label: "Signal",
                command: [Quickshell.env("KESTREL_MESSENGER")],
                startupClass: "signal"
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
