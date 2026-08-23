pragma ComponentBehavior: Bound

import QtQuick

BarModeButton {
    id: root

    signal detailRequested

    visible: NetworkState.wiredDevice !== null
    icon: NetworkState.wiredConnected ? "󰈀" : "󰈂"
    interactive: NetworkState.available
    secondaryInteractive: NetworkState.available && NetworkState.wiredNetwork !== null
    onActivated: root.detailRequested()
    onSecondaryActivated: NetworkState.toggleWired()
}
