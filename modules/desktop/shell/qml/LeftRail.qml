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
                command: [Quickshell.env("KESTREL_BROWSER"), "--new-window", "--ozone-platform=wayland"]
            },
            {
                label: "Terminal",
                command: [Quickshell.env("KESTREL_TERMINAL")]
            },
            {
                label: "Email",
                command: [Quickshell.env("KESTREL_EMAIL")]
            },
            {
                label: "Signal",
                command: [Quickshell.env("KESTREL_MESSENGER")]
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
                cursorShape: Qt.PointingHandCursor
                onClicked: Quickshell.execDetached(["uwsm", "app", "--"].concat(appButton.modelData.command))
            }
        }
    }
}
