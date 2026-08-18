pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    readonly property bool powerHovered: powerButton.hovered
    readonly property real powerX: powerButton.x

    height: 24
    spacing: Style.barItemGap

    Power {
        id: powerButton
    }

    IdleIndicator {}
}
