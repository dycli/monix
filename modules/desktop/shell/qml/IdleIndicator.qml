import QtQuick

Item {
    width: 14
    height: 24
    visible: PowerService.idleInhibited

    Text {
        anchors.fill: parent
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: 10
            weight: Style.fontWeight
        }
        horizontalAlignment: Text.AlignHCenter
        renderType: Text.NativeRendering
        text: ""
        verticalAlignment: Text.AlignVCenter
    }
}
