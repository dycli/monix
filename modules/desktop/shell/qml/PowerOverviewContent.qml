import QtQuick

Item {
    id: root

    property string kind: "battery"
    property string profileLabel: ""

    implicitWidth: kind === "profile" ? profile.implicitWidth : battery.implicitWidth
    implicitHeight: 24
    width: implicitWidth
    height: implicitHeight

    BatteryBarStatus {
        id: battery

        anchors.right: parent.right
        visible: root.kind === "battery"
    }

    BarModeButton {
        id: profile

        anchors.right: parent.right
        icon: "󰓅"
        interactive: false
        label: root.profileLabel
        visible: root.kind === "profile"
    }
}
