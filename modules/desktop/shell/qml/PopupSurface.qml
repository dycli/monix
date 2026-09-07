pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

Item {
    id: root

    default property alias contentData: content.data

    property bool feathered: true
    property bool expanded: true
    property real revealRadius: expanded ? Math.sqrt(width * width + height * height) : 0

    anchors.fill: parent

    Item {
        id: content

        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: false
            maskEnabled: true
            maskSource: revealMask
        }

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
    }

    Item {
        id: revealMask

        anchors.fill: parent
        clip: true
        layer.enabled: true
        visible: false

        Rectangle {
            x: revealMask.width - root.revealRadius
            y: -root.revealRadius
            width: root.revealRadius * 2
            height: width
            radius: width / 2
            color: "white"
            antialiasing: true
        }
    }

    Behavior on revealRadius {
        NumberAnimation {
            duration: Style.popupRevealDuration
            easing.type: Easing.OutCubic
        }
    }
}
