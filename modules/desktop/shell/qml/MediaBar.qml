pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    property real maximumDetailsWidth: 240
    property real revealProgress: 0

    readonly property bool hovered: pointer.hovered
    readonly property real restingWidth: controls.implicitWidth
    readonly property real detailsWidth: Math.min(maximumDetailsWidth, track.implicitWidth)
    readonly property real revealedWidth: detailsWidth > 0
        ? Style.barItemGap + detailsWidth : 0

    implicitWidth: restingWidth + revealProgress * revealedWidth
    implicitHeight: 24
    width: implicitWidth
    height: implicitHeight
    clip: true

    HoverHandler {
        id: pointer
    }

    Item {
        id: detailsViewport

        anchors {
            left: parent.left
            verticalCenter: parent.verticalCenter
        }
        width: root.revealProgress * root.revealedWidth
        height: 24
        clip: true

        Text {
            id: track

            anchors.verticalCenter: parent.verticalCenter
            x: detailsViewport.width - width
            width: root.detailsWidth
            color: Style.foregroundColor
            elide: Text.ElideRight
            font {
                family: Style.fontFamily
                pixelSize: Style.textFontSize
                weight: Style.fontWeight
            }
            horizontalAlignment: Text.AlignRight
            renderType: Text.NativeRendering
            text: MediaState.artist.length > 0
                ? MediaState.artist + " — " + MediaState.title : MediaState.title

            MouseArea {
                anchors.fill: parent
                cursorShape: MediaState.player?.canRaise
                    ? Qt.PointingHandCursor : Qt.ArrowCursor
                enabled: MediaState.player?.canRaise || false
                onClicked: MediaState.player.raise()
            }
        }
    }

    Row {
        id: controls

        anchors {
            right: parent.right
            verticalCenter: parent.verticalCenter
        }
        height: 24
        spacing: 2

        Repeater {
            model: ["previous", "toggle", "next"]

            delegate: Item {
                id: control

                required property string modelData

                readonly property bool available: {
                    switch (modelData) {
                    case "previous": return MediaState.player?.canGoPrevious || false;
                    case "toggle": return MediaState.player?.canTogglePlaying || false;
                    default: return MediaState.player?.canGoNext || false;
                    }
                }
                readonly property string icon: {
                    switch (modelData) {
                    case "previous": return "󰒮";
                    case "toggle": return MediaState.player?.isPlaying ? "" : "";
                    default: return "󰒭";
                    }
                }

                function activate(): void {
                    switch (modelData) {
                    case "previous": MediaState.player.previous(); break;
                    case "toggle": MediaState.player.togglePlaying(); break;
                    default: MediaState.player.next();
                    }
                }

                width: available ? 20 : 0
                height: 24
                visible: available

                Text {
                    anchors.centerIn: parent
                    color: Style.foregroundColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.iconFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: control.icon
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: control.activate()
                }
            }
        }
    }
}
