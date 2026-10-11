import QtQuick

Text {
    id: root

    property real maximumWidth: 240

    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(maximumWidth, implicitWidth)
    color: Style.foregroundColor
    elide: Text.ElideRight
    font {
        family: Style.fontFamily
        pixelSize: Style.textFontSize
        weight: Style.fontWeight
    }
    renderType: Text.NativeRendering
    text: MediaState.artist.length > 0
        ? MediaState.artist + " \u2014 " + MediaState.title : MediaState.title
    visible: MediaState.available && text.length > 0 && width > 0

    MouseArea {
        anchors.fill: parent
        cursorShape: MediaState.player?.canRaise ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: MediaState.player?.canRaise || false
        onClicked: MediaState.player.raise()
    }
}
