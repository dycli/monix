pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Bluetooth

QtObject {
    id: root

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
    readonly property bool available: adapter !== null
    readonly property bool enabled: available && adapter.enabled
    readonly property var connectedDevice: devices.find(device => device && device.connected) || null
    readonly property bool connected: connectedDevice !== null
    readonly property string icon: enabled ? "󰂯" : "󰂲"
    readonly property string label: connected ? deviceLabel(connectedDevice) : ""

    function deviceLabel(device): string {
        const name = device.name || device.deviceName || "Bluetooth";
        if (!device.batteryAvailable)
            return name;
        return name + " " + Math.round(device.battery * 100) + "%";
    }
}
