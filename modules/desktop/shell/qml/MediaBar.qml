pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    required property real maximumWidth

    readonly property real minimumWidth: controls.implicitWidth + 44
    readonly property real naturalWidth: controls.implicitWidth + Style.barItemGap
        + track.implicitWidth

    implicitWidth: Math.min(maximumWidth, naturalWidth)
    implicitHeight: 24
    width: implicitWidth
    height: implicitHeight
    clip: true

    Row {
        id: controls

        anchors {
            left: parent.left
            verticalCenter: parent.verticalCenter
        }
        height: 24
        spacing: 2

        Repeater {
            model: [
                {
                    "icon": "󰒮",
                    "available": MediaState.player?.canGoPrevious || false,
                    "action": () => MediaState.player.previous()
                },
                {
                    "icon": MediaState.player?.isPlaying ? "" : "",
                    "available": MediaState.player?.canTogglePlaying || false,
                    "action": () => MediaState.player.togglePlaying()
                },
                {
                    "icon": "󰒭",
                    "available": MediaState.player?.canGoNext || false,
                    "action": () => MediaState.player.next()
                }
            ]

            delegate: Item {
                id: control

                required property var modelData

                width: 20
                height: 24
                visible: modelData.available

                Text {
                    anchors.centerIn: parent
                    color: Style.foregroundColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.iconFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: control.modelData.icon
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: control.modelData.action()
                }
            }
        }
    }

    Text {
        id: track

        anchors {
            left: controls.right
            leftMargin: Style.barItemGap
            right: parent.right
            verticalCenter: parent.verticalCenter
        }
        color: Style.foregroundColor
        elide: Text.ElideRight
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: MediaState.artist.length > 0
            ? MediaState.artist + " — " + MediaState.title : MediaState.title

        MouseArea {
            anchors.fill: parent
            cursorShape: MediaState.player?.canRaise ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: MediaState.player?.canRaise || false
            onClicked: MediaState.player.raise()
        }
    }
}
