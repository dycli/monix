import QtQuick

Item {
    id: root

    default property alias contentData: content.data

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

        Rectangle {
            id: content

            width: viewport.width
            height: root.height
            antialiasing: true
            border.color: Style.panelBorderColor
            border.width: Style.popupBorderWidth
            color: Style.popupBackgroundColor
            radius: Style.popupRadius
        }
    }

    Behavior on revealHeight {
        NumberAnimation {
            duration: Style.popupRevealDuration
            easing.type: Easing.OutCubic
        }
    }
}
