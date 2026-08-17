pragma Singleton

import QtQuick

QtObject {
    readonly property string fontFamily: "ComicCodeLigatures Nerd Font"
    readonly property int fontWeight: Font.Bold
    readonly property color foregroundColor: "#ffffff"
    readonly property color inactiveWorkspaceColor: "#c5c9d0"
    readonly property color lowBatteryColor: "#d26a6a"
    readonly property int iconFontSize: 14
    readonly property int smallFontSize: 9
    readonly property int textFontSize: 10
}
