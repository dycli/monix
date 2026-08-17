import QtQuick
import Quickshell.Wayland

Text {
    readonly property var activeWindow: ToplevelManager.activeToplevel

    color: "#aeb3bd"
    elide: Text.ElideRight
    font {
        family: "Noto Sans"
        pixelSize: 12
    }
    renderType: Text.NativeRendering
    text: activeWindow?.title || ""
    visible: text.length > 0
}
