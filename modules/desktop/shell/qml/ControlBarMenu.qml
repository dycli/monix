pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Bluetooth

Row {
    id: root

    signal closeRequested
    signal modeRequested(string mode)

    height: 24
    spacing: 4

    BarModeButton {
        active: NetworkState.wifiEnabled && NetworkState.connectedNetwork !== null
        enabled: NetworkState.available && NetworkState.wifiHardwareEnabled
        label: NetworkState.connectedNetwork ? "Wi-Fi " + NetworkState.connectedNetwork.name : "Wi-Fi"
        onActivated: root.modeRequested("wifi")
    }

    BarModeButton {
        active: Bluetooth.defaultAdapter ? Bluetooth.defaultAdapter.enabled : false
        enabled: false
        label: "Bluetooth"
    }

    BarModeButton {
        enabled: false
        label: "Sound"
    }

    BarModeButton {
        enabled: false
        label: "Display"
    }

    SettingsButton {
        anchors.verticalCenter: parent.verticalCenter
        onMenuToggleRequested: root.closeRequested()
    }
}
