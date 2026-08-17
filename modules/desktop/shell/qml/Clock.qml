import QtQuick
import Quickshell

Text {
    id: root

    signal clicked

    property string format: "HH:mm"
    property int fontPixelSize: Style.textFontSize

    color: Style.foregroundColor
    font {
        family: Style.fontFamily
        pixelSize: root.fontPixelSize
        weight: Style.fontWeight
    }
    renderType: Text.NativeRendering
    text: Qt.formatDateTime(clock.date, format)

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
