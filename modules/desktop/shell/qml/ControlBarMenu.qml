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
        active: NetworkState.connected
        enabled: NetworkState.available && (NetworkState.wiredDevice !== null || NetworkState.wifiHardwareEnabled)
        icon: NetworkState.primaryIcon
        label: NetworkState.primaryLabel
        onActivated: root.modeRequested("network")
    }

    BarModeButton {
        active: Bluetooth.defaultAdapter ? Bluetooth.defaultAdapter.enabled : false
        enabled: false
        icon: "󰂯"
        label: "Bluetooth"
    }

    BarModeButton {
        enabled: false
        icon: "󰕾"
        label: "Sound"
    }

    BarModeButton {
        enabled: false
        icon: "󰍹"
        label: "Display"
    }

    SettingsButton {
        anchors.verticalCenter: parent.verticalCenter
        onMenuToggleRequested: root.closeRequested()
    }
}
