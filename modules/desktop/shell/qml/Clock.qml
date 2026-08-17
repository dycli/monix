import QtQuick
import Quickshell

Text {
    id: root

    property string format: "HH:mm"
    property int fontWeight: Font.Normal

    color: "#eef0f4"
    font {
        family: "Noto Sans"
        pixelSize: 12
        weight: root.fontWeight
    }
    renderType: Text.NativeRendering
    text: Qt.formatDateTime(clock.date, format)

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}
