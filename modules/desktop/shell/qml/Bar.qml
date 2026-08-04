// Placeholder bar: a strip and a clock, proving the layer-shell window
// and the render loop end to end. Everything else is design work that
// has not happened yet.
import Quickshell
import QtQuick

PanelWindow {
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 24
    color: "#c0101010"

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Text {
        anchors.centerIn: parent
        color: "#e6e6e6"
        font.pixelSize: 12
        text: Qt.formatDateTime(clock.date, "ddd d MMM  HH:mm")
    }
}
