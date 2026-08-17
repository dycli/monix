pragma Singleton

import QtQuick

QtObject {
    readonly property string fontFamily: "ComicCodeLigatures Nerd Font"
    readonly property int fontWeight: 500
    readonly property color foregroundColor: "#ffffff"
    readonly property color inactiveWorkspaceColor: "#c5c9d0"
    readonly property color lowBatteryColor: "#d26a6a"
    readonly property color mutedColor: "#a9adb4"
    readonly property color panelColor: "#151515"
    readonly property color panelCardColor: "#242424"
    readonly property color panelBorderColor: "#3a3a3a"
    readonly property int iconFontSize: 14
    readonly property int smallFontSize: 10
    readonly property int textFontSize: 10
    readonly property font panelTextFont: Qt.font({
        family: fontFamily,
        pixelSize: 10,
        weight: 500
    })
    readonly property font panelTitleFont: Qt.font({
        family: fontFamily,
        pixelSize: 10,
        weight: 500
    })
    readonly property font panelValueFont: Qt.font({
        family: fontFamily,
        pixelSize: 10,
        weight: 500
    })
}
