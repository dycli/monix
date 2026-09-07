pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    default property alias contentData: content.data

    property bool feathered: true
    property bool expanded: true
    property real revealHeight: expanded ? height : 0

    anchors.fill: parent

    Item {
        id: viewport

        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
        }
        height: root.revealHeight
        clip: true

        Item {
            id: content

            width: viewport.width
            height: root.height

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
    }

    Behavior on revealHeight {
        NumberAnimation {
            duration: Style.popupRevealDuration
            easing.type: Easing.OutCubic
        }
    }
}
