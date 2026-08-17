import QtQuick
import Quickshell.Wayland

Text {
    readonly property var activeWindow: ToplevelManager.activeToplevel

    color: "#aeb3bd"
    elide: Text.ElideRight
    font {
        family: Style.fontFamily
        pixelSize: 12
        weight: Style.fontWeight
    }
    renderType: Text.NativeRendering
    text: activeWindow?.title || ""
    visible: text.length > 0
}
