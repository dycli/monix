pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    required property string screenName
    required property var targetScreen
    required property int popupLeft
    required property int popupTop

    readonly property var emojis: [
        ["😀", "grinning happy face"], ["😃", "happy smile face"],
        ["😄", "smile laugh face"], ["😁", "beaming grin face"],
        ["😂", "tears joy laugh face"], ["🤣", "rolling laugh face"],
        ["😊", "smiling blush face"], ["🙂", "slight smile face"],
        ["😉", "wink face"], ["😍", "heart eyes love face"],
        ["🥰", "hearts love face"], ["😘", "kiss face"],
        ["😎", "cool sunglasses face"], ["🤔", "thinking face"],
        ["🫡", "salute face"], ["🤩", "star eyes excited face"],
        ["🥳", "party celebration face"], ["😅", "sweat smile face"],
        ["😭", "crying face"], ["😢", "sad tear face"],
        ["😡", "angry face"], ["🙃", "upside down face"],
        ["🫠", "melting face"], ["🤯", "mind blown face"],
        ["👍", "thumbs up yes"], ["👎", "thumbs down no"],
        ["👌", "okay hand"], ["✌️", "victory peace hand"],
        ["🤞", "fingers crossed luck"], ["👏", "clap applause"],
        ["🙌", "raised hands celebrate"], ["🙏", "please thanks pray"],
        ["👋", "wave hello goodbye"], ["🤝", "handshake agreement"],
        ["💪", "strong muscle"], ["🫶", "heart hands love"],
        ["❤️", "red heart love"], ["🧡", "orange heart"],
        ["💛", "yellow heart"], ["💚", "green heart"],
        ["💙", "blue heart"], ["💜", "purple heart"],
        ["🖤", "black heart"], ["💔", "broken heart"],
        ["✨", "sparkles magic"], ["🔥", "fire hot"],
        ["🎉", "party popper celebration"], ["💯", "hundred perfect"],
        ["✅", "check yes done"], ["❌", "cross no wrong"],
        ["⚠️", "warning caution"], ["❓", "question mark"],
        ["💡", "light bulb idea"], ["🚀", "rocket launch"],
        ["⭐", "star favorite"], ["🌈", "rainbow"],
        ["☀️", "sun sunny"], ["🌙", "moon night"],
        ["🐶", "dog animal"], ["🐱", "cat animal"],
        ["🐦", "bird animal"], ["🦊", "fox animal"],
        ["🌱", "seedling plant grow"], ["🌸", "flower blossom"],
        ["🍎", "apple fruit"], ["🍕", "pizza food"],
        ["☕", "coffee drink"], ["🍺", "beer drink"],
        ["🎵", "music note"], ["🎮", "game controller"],
        ["💻", "computer laptop"], ["📱", "phone mobile"],
        ["📌", "pin marker"], ["🔒", "lock secure"]
    ]

    readonly property var results: filtered(search.text)
    readonly property int columns: Math.max(1, Math.floor(grid.width / grid.cellWidth))

    function filtered(query: string): var {
        const needle = query.trim().toLowerCase();
        if (needle.length === 0)
            return emojis;
        return emojis.filter(entry => entry[1].includes(needle)
            || entry[0].includes(needle));
    }

    function choose(index: int): void {
        if (index >= 0 && index < results.length)
            ClipboardState.pasteText(results[index][0]);
    }

    color: "transparent"
    implicitWidth: 250
    implicitHeight: 300
    screen: targetScreen
    visible: ClipboardPanelService.isOpen(screenName)
        && ClipboardPanelService.emojiOpen

    anchors {
        top: true
        left: true
    }
    margins {
        left: popupLeft
        top: popupTop
    }
    exclusiveZone: 0

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "kestrel:popout"
    WlrLayershell.keyboardFocus: root.visible
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    onVisibleChanged: {
        if (visible) {
            search.text = "";
            grid.currentIndex = 0;
            focusTimer.start();
        }
    }

    Timer {
        id: focusTimer

        interval: 0
        onTriggered: search.forceActiveFocus()
    }

    PopupSurface {
        Column {
            anchors {
                fill: parent
                margins: 6
            }
            spacing: 6

            Item {
                width: parent.width
                height: 30

                Text {
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                    }
                    color: Style.panelMutedColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.panelFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: "Search emoji"
                    visible: search.text.length === 0
                }

                TextInput {
                    id: search

                    anchors.fill: parent
                    color: Style.foregroundColor
                    clip: true
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.panelFontSize
                        weight: Style.fontWeight
                    }
                    selectionColor: Style.foregroundColor
                    selectedTextColor: "#000000"
                    verticalAlignment: TextInput.AlignVCenter
                    onTextChanged: grid.currentIndex = 0

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {
                            ClipboardPanelService.close();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Right && root.results.length > 0) {
                            grid.currentIndex = Math.min(root.results.length - 1,
                                grid.currentIndex + 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Left && root.results.length > 0) {
                            grid.currentIndex = Math.max(0, grid.currentIndex - 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down && root.results.length > 0) {
                            grid.currentIndex = Math.min(root.results.length - 1,
                                grid.currentIndex + root.columns);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up && root.results.length > 0) {
                            grid.currentIndex = Math.max(0,
                                grid.currentIndex - root.columns);
                            event.accepted = true;
                        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                && root.results.length > 0) {
                            root.choose(grid.currentIndex);
                            event.accepted = true;
                        }
                    }

                    Rectangle {
                        anchors {
                            left: parent.left
                            right: parent.right
                            bottom: parent.bottom
                        }
                        height: 1
                        color: Style.panelBorderColor
                    }
                }
            }

            GridView {
                id: grid

                width: parent.width
                height: parent.height - 72
                cellWidth: 34
                cellHeight: 34
                clip: true
                model: root.results

                delegate: Rectangle {
                    id: emojiCell

                    required property int index
                    required property var modelData

                    width: grid.cellWidth
                    height: grid.cellHeight
                    color: index === grid.currentIndex || pointer.containsMouse
                        ? Qt.rgba(1, 1, 1, 0.09) : "transparent"
                    radius: Style.popupRadius

                    Text {
                        anchors.centerIn: parent
                        font {
                            family: "Noto Color Emoji"
                            pixelSize: 18
                        }
                        renderType: Text.NativeRendering
                        text: emojiCell.modelData[0]
                    }

                    MouseArea {
                        id: pointer

                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: root.choose(emojiCell.index)
                        onEntered: grid.currentIndex = emojiCell.index
                    }
                }

                Text {
                    anchors.centerIn: parent
                    color: Style.panelMutedColor
                    font {
                        family: Style.fontFamily
                        pixelSize: Style.panelFontSize
                        weight: Style.fontWeight
                    }
                    renderType: Text.NativeRendering
                    text: "No emoji found"
                    visible: root.results.length === 0
                }
            }

            Text {
                width: parent.width
                color: Style.panelMutedColor
                elide: Text.ElideRight
                font {
                    family: Style.fontFamily
                    pixelSize: Style.smallFontSize
                    weight: Style.fontWeight
                }
                horizontalAlignment: Text.AlignHCenter
                renderType: Text.NativeRendering
                text: root.results.length > 0 && grid.currentIndex >= 0
                    ? root.results[grid.currentIndex][1] : ""
            }
        }
    }
}
