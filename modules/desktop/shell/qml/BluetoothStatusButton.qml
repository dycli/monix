pragma ComponentBehavior: Bound

import QtQuick

BarModeButton {
    id: root

    signal detailRequested

    visible: BluetoothState.available
    interactive: BluetoothState.available
    icon: BluetoothState.icon
    label: BluetoothState.label
    secondaryInteractive: BluetoothState.available
    onActivated: root.detailRequested()
    onSecondaryActivated: BluetoothState.toggleEnabled()
}
