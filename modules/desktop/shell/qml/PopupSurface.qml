import QtQuick

Rectangle {
    id: root

    property bool fadesDown: true
    property bool expanded: true

    anchors.fill: parent
    antialiasing: true
    border.color: Style.panelBorderColor
    border.width: Style.popupBorderWidth
    color: "transparent"
    gradient: Gradient {
        orientation: Gradient.Vertical

        GradientStop {
            position: 0
            color: root.fadesDown
                ? Style.popupGradientTopColor : Style.popupBackgroundColor
        }

        GradientStop {
            position: 1
            color: root.fadesDown
                ? Style.popupGradientBottomColor : Style.popupBackgroundColor
        }
    }
    opacity: expanded ? 1 : 0
    radius: Style.popupRadius
    scale: expanded ? 1 : 0.12
    transformOrigin: Item.TopRight

    Behavior on opacity {
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    Behavior on scale {
        NumberAnimation {
            duration: 240
            easing {
                type: Easing.OutBack
                overshoot: 1.15
            }
        }
    }
}
