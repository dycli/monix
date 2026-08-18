pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    implicitWidth: PrivacyState.active ? indicators.implicitWidth : 0
    implicitHeight: 24
    width: implicitWidth
    height: implicitHeight
    visible: PrivacyState.active

    Row {
        id: indicators

        anchors.centerIn: parent
        spacing: Style.barItemGap

        Repeater {
            model: [
                { "active": PrivacyState.microphoneActive, "icon": "" },
                { "active": PrivacyState.cameraActive, "icon": "" },
                { "active": PrivacyState.screenSharingActive, "icon": "󰍹" }
            ]

            delegate: Text {
                required property var modelData

                width: modelData.active ? 16 : 0
                height: 24
                color: Style.foregroundColor
                font {
                    family: Style.fontFamily
                    pixelSize: Style.iconFontSize
                    weight: Style.fontWeight
                }
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                renderType: Text.NativeRendering
                text: modelData.icon
                visible: modelData.active
            }
        }
    }
}
