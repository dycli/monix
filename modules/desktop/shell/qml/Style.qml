pragma Singleton

import QtQuick

QtObject {
    readonly property string fontFamily: "ComicCodeLigatures Nerd Font"
    readonly property int fontWeight: 500
    readonly property color foregroundColor: "#ffffff"
    readonly property color inactiveWorkspaceColor: "#c5c9d0"
    readonly property color lowBatteryColor: "#d26a6a"
    readonly property color panelColor: "#151515"
    readonly property color popupBackgroundColor: Qt.rgba(21 / 255, 21 / 255, 21 / 255, 0.7)
    readonly property color panelBorderColor: "#343434"
    readonly property color panelMutedColor: "#a9adb4"
    readonly property int iconFontSize: 14
    readonly property int smallFontSize: 10
    readonly property int textFontSize: 10
    readonly property int panelFontSize: 12
    readonly property int panelTitleFontSize: 15
    readonly property int barItemGap: 16
}
