import QtQuick

Row {
    height: 24
    spacing: Style.barItemGap

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.rate
        visible: !PowerService.full
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.time
        visible: !PowerService.full
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: PowerService.percentage <= 15 && !PowerService.charging
            ? Style.lowBatteryColor : Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: PowerService.percentage + "%"
    }
}
