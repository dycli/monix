pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal powerActivated

    height: 24
    spacing: Style.barItemGap

    Power {
        onActivated: root.powerActivated()
    }

    IdleIndicator {}
}
