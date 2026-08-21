pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal powerActivated

    readonly property bool powerHovered: powerButton.hovered
    readonly property real powerX: powerButton.x

    height: 24
    spacing: Style.barItemGap

    Power {
        id: powerButton

        onActivated: root.powerActivated()
    }

    IdleIndicator {}
}
