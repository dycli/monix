pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Bluetooth

Row {
    id: root

    signal backRequested
    signal closeRequested

    height: 24
    spacing: 4

    Component.onCompleted: BluetoothState.startScan()
    Component.onDestruction: BluetoothState.stopScan()

    BarModeButton {
        icon: "󰁍"
        onActivated: root.backRequested()
    }

    BarModeButton {
        active: BluetoothState.enabled
        enabled: BluetoothState.available
        icon: BluetoothState.icon
        label: BluetoothState.enabled ? "Bluetooth On" : "Bluetooth Off"
        onActivated: BluetoothState.toggleEnabled()
    }

    BarModeButton {
        active: BluetoothState.discovering
        enabled: BluetoothState.enabled
        icon: "󰂰"
        label: BluetoothState.discovering ? "Scanning" : "Scan"
        onActivated: BluetoothState.toggleScan()
    }

    Repeater {
        model: BluetoothState.visibleDeviceRows

        delegate: BarModeButton {
            required property var modelData

            active: modelData.connected
            enabled: !modelData.pairing
                && modelData.state !== BluetoothDeviceState.Connecting
                && modelData.state !== BluetoothDeviceState.Disconnecting
            icon: modelData.icon
            label: BluetoothState.statusLabel(modelData)
            maximumWidth: 150
            secondaryInteractive: modelData.paired
            onActivated: BluetoothState.activateDevice(modelData.address)
            onSecondaryActivated: BluetoothState.forgetDevice(modelData.address)
        }
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.inactiveWorkspaceColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: !BluetoothState.available
            ? "No Bluetooth adapter"
            : (BluetoothState.enabled ? "No devices" : "Bluetooth Off")
        visible: !BluetoothState.enabled || BluetoothState.visibleDeviceRows.length === 0
    }

    SettingsButton {
        anchors.verticalCenter: parent.verticalCenter
        onMenuToggleRequested: root.closeRequested()
    }
}
