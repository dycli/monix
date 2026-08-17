import QtQuick
import Quickshell.Wayland

Text {
    readonly property var activeWindow: ToplevelManager.activeToplevel

    color: Style.foregroundColor
    elide: Text.ElideRight
    font {
        family: Style.fontFamily
        pixelSize: Style.textFontSize
        weight: Style.fontWeight
    }
    renderType: Text.NativeRendering
    text: activeWindow?.title || ""
    visible: text.length > 0
}
