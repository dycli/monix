pragma ComponentBehavior: Bound

import QtQuick

BarModeButton {
    id: root

    signal detailRequested

    active: NetworkState.connected
    icon: NetworkState.primaryIcon
    interactive: NetworkState.available
        && (NetworkState.wiredDevice !== null || NetworkState.wifiHardwareEnabled)
    label: NetworkState.primaryLabel
    secondaryInteractive: NetworkState.available
    onActivated: root.detailRequested()
    onSecondaryActivated: NetworkState.disablePrimary()
}
