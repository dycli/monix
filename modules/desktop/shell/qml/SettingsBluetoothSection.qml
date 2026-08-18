pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Bluetooth

Column {
    id: root

    required property bool panelVisible

    spacing: 8

    onPanelVisibleChanged: {
        if (panelVisible && BluetoothState.enabled)
            BluetoothState.startScan();
        else
            BluetoothState.stopScan();
    }

    Component.onCompleted: {
        if (panelVisible && BluetoothState.enabled)
            BluetoothState.startScan();
    }
    Component.onDestruction: BluetoothState.stopScan()

    Text {
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelTitleFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Bluetooth"
    }

    SettingsChoiceButton {
        width: parent.width
        active: BluetoothState.enabled
        icon: BluetoothState.icon
        label: BluetoothState.enabled ? "Bluetooth" : "Bluetooth off"
        detail: BluetoothState.connectedDevice
            ? BluetoothState.deviceLabel(BluetoothState.connectedDevice) : ""
        onActivated: {
            const enabling = !BluetoothState.enabled;
            if (!enabling)
                BluetoothState.stopScan();
            BluetoothState.toggleEnabled();
            if (enabling)
                BluetoothState.startScan();
        }
    }

    SettingsChoiceButton {
        width: parent.width
        active: BluetoothState.discovering
        interactive: BluetoothState.enabled
        icon: "󰂰"
        label: BluetoothState.discovering ? "Scanning" : "Scan for devices"
        onActivated: BluetoothState.toggleScan()
    }

    Repeater {
        model: BluetoothState.visibleDeviceRows

        delegate: SettingsChoiceButton {
            required property var modelData

            width: root.width
            active: modelData.connected
            interactive: !modelData.pairing
                && modelData.state !== BluetoothDeviceState.Connecting
                && modelData.state !== BluetoothDeviceState.Disconnecting
            secondaryInteractive: modelData.paired
            icon: modelData.icon
            label: BluetoothState.statusLabel(modelData)
            detail: modelData.connected ? "Connected" : ""
            onActivated: BluetoothState.activateDevice(modelData.address)
            onSecondaryActivated: BluetoothState.forgetDevice(modelData.address)
        }
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: BluetoothState.enabled ? "No devices found" : "Bluetooth is off"
        visible: BluetoothState.visibleDeviceRows.length === 0
    }
}
