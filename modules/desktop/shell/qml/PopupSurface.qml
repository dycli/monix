import QtQuick

Item {
    id: root

    property bool feathered: true
    property bool expanded: true

    anchors.fill: parent

    BorderImage {
        anchors.fill: parent
        border {
            bottom: 16
            left: 16
        }
        source: "assets/popup-glass.svg"
        visible: root.feathered
    }

    Rectangle {
        anchors.fill: parent
        border.color: Style.panelBorderColor
        border.width: Style.popupBorderWidth
        color: Style.launcherBackgroundColor
        radius: Style.popupRadius
        visible: !root.feathered
    }

    opacity: expanded ? 1 : 0

    Behavior on opacity {
        NumberAnimation {
            duration: Style.popupFadeDuration
            easing.type: Easing.InOutSine
        }
    }
}
