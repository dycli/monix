pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    implicitWidth: controls.implicitWidth
    implicitHeight: 24
    width: implicitWidth
    height: implicitHeight

    Row {
        id: controls

        anchors.verticalCenter: parent.verticalCenter
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
