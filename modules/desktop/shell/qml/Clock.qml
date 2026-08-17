import QtQuick
import Quickshell

Text {
    id: root

    property string format: "HH:mm"

    color: "#eef0f4"
    font {
        family: Style.fontFamily
        pixelSize: 12
        weight: Style.fontWeight
    }
    renderType: Text.NativeRendering
    text: Qt.formatDateTime(clock.date, format)

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}
