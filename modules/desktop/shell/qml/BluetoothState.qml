pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Bluetooth
import Quickshell.Io

QtObject {
    id: root

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var devices: adapter && adapter.devices ? adapter.devices.values : []
    readonly property bool available: adapter !== null
    readonly property bool enabled: available && adapter.enabled
    readonly property bool discovering: enabled && adapter.discovering
    readonly property var connectedDevices: sortedDevices(devices.filter(device => device && device.connected))
    readonly property var knownDevices: sortedDevices(devices.filter(device => device
        && !device.connected && (device.paired || device.bonded || device.trusted)))
    readonly property var discoveredDevices: sortedDevices(devices.filter(device => device
        && !device.connected && !device.paired && !device.bonded && !device.trusted
        && !device.blocked && hasHumanName(device)))
    readonly property var connectedDevice: connectedDevices[0] || null
    readonly property bool connected: connectedDevice !== null
    readonly property string icon: !enabled ? "󰂲" : (connected ? "󰂱" : "󰂯")
    readonly property string label: connected ? deviceLabel(connectedDevice) : ""
    readonly property var visibleDeviceRows: deviceRows().slice(0, 6)

    property bool scanRequested: false
    property bool ownsDiscovery: false
    property bool ownsPairable: false

    property Process pairingAgent: Process {
        command: ["bt-agent", "-c", "NoInputNoOutput"]
        running: root.scanRequested && root.enabled
    }

    property Timer discoveryRetry: Timer {
        interval: 1000
        repeat: true
        triggeredOnStart: true
        running: root.scanRequested && root.enabled && (!root.discovering || !root.adapter.pairable)
        onTriggered: {
            if (!root.adapter.pairable) {
                root.ownsPairable = true;
                root.adapter.pairable = true;
            }
            if (!root.discovering) {
                root.ownsDiscovery = true;
                root.adapter.discovering = true;
            }
        }
    }

    property Timer discoveryStop: Timer {
        id: discoveryStop

        property int attempts: 0

        interval: 1000
        repeat: true
        running: !root.scanRequested && root.ownsDiscovery && root.discovering
        onRunningChanged: {
            if (running)
                attempts = 0;
        }
        onTriggered: {
            attempts += 1;
            if (attempts > 3) {
                root.ownsDiscovery = false;
                return;
            }
            root.adapter.discovering = false;
        }
    }

    property Connections adapterConnections: Connections {
        target: root.adapter

        function onDiscoveringChanged(): void {
            if (!root.discovering && !root.scanRequested)
                root.ownsDiscovery = false;
        }
    }

    function deviceLabel(device): string {
        const name = device.deviceName || device.name || "Bluetooth";
        if (!device.batteryAvailable)
            return name;
        return name + " " + Math.round(device.battery * 100) + "%";
    }

    function hasHumanName(device): bool {
        const name = String(device.deviceName || device.name || "").trim();
        return name.length > 0
            && !/^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(name)
            && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(name);
    }

    function sortedDevices(input) {
        return input.filter(device => hasHumanName(device)).slice().sort((left, right) => {
            return String(left.deviceName || left.name).localeCompare(String(right.deviceName || right.name));
        });
    }

    function deviceRows() {
        const ordered = connectedDevices.concat(knownDevices);
        if (discovering)
            ordered.push(...discoveredDevices);
        return ordered.map(device => ({
            address: device.address || "",
            name: device.deviceName || device.name || "Bluetooth",
            connected: device.connected,
            paired: device.paired || device.bonded || device.trusted,
            pairing: device.pairing,
            state: device.state,
            batteryAvailable: device.batteryAvailable,
            battery: device.battery,
            icon: deviceIcon(device)
        }));
    }

    function deviceIcon(device): string {
        const description = String((device.icon || "") + " " + (device.deviceName || device.name || "")).toLowerCase();
        if (/head|audio|airpod|earbud/.test(description))
            return "󰋋";
        if (/mouse/.test(description))
            return "󰍽";
        if (/keyboard/.test(description))
            return "󰌌";
        if (/phone|iphone|android/.test(description))
            return "󰄜";
        if (/speaker/.test(description))
            return "󰓃";
        if (/gamepad|controller/.test(description))
            return "󰊴";
        return "󰂯";
    }

    function deviceFor(address: string) {
        return devices.find(device => device && device.address === address) || null;
    }

    function statusLabel(row): string {
        if (row.pairing)
            return row.name + " Pairing";
        if (row.state === BluetoothDeviceState.Connecting)
            return row.name + " Connecting";
        if (row.state === BluetoothDeviceState.Disconnecting)
            return row.name + " Disconnecting";
        if (row.connected && row.batteryAvailable)
            return row.name + " " + Math.round(row.battery * 100) + "%";
        return row.name;
    }

    function startScan(): void {
        scanRequested = true;
        if (available && !adapter.pairable) {
            ownsPairable = true;
            adapter.pairable = true;
        }
    }

    function stopScan(): void {
        scanRequested = false;
        if (available && ownsPairable)
            adapter.pairable = false;
        ownsPairable = false;
    }

    function toggleScan(): void {
        if (scanRequested)
            stopScan();
        else
            startScan();
    }

    function toggleEnabled(): void {
        if (available)
            adapter.enabled = !adapter.enabled;
    }

    function activateDevice(address: string): void {
        const device = deviceFor(address);
        if (!device)
            return;
        if (device.connected) {
            device.disconnect();
            return;
        }
        device.trusted = true;
        if (device.paired || device.bonded)
            device.connect();
        else
            device.pair();
    }

    function forgetDevice(address: string): void {
        const device = deviceFor(address);
        if (device)
            device.forget();
    }

}
