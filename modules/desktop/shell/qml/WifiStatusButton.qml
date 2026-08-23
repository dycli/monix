pragma ComponentBehavior: Bound

import QtQuick

BarModeButton {
    id: root

    signal detailRequested

    visible: NetworkState.wifiDevice !== null
    icon: NetworkState.wifiEnabled ? "󰖩" : "󰖪"
    interactive: NetworkState.available && NetworkState.wifiHardwareEnabled
    label: NetworkState.connectedWifiNetwork
        ? NetworkState.connectedWifiNetwork.name + " "
            + Math.round(NetworkState.connectedWifiNetwork.signalStrength * 100) + "%"
        : ""
    secondaryInteractive: NetworkState.available && NetworkState.wifiHardwareEnabled
    onActivated: root.detailRequested()
    onSecondaryActivated: NetworkState.toggleWifi()
}
