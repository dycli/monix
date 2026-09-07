pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import Quickshell.Networking

QtObject {
    id: root

    readonly property bool available: Networking.backend === NetworkBackendType.NetworkManager
    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property var wifiDevice: findDevice(DeviceType.Wifi)
    readonly property var wiredDevice: findDevice(DeviceType.Wired)
    readonly property var wiredNetwork: wiredDevice ? wiredDevice.network : null
    readonly property var networkObjects: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
    readonly property var networks: sortedNetworks()

    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property bool wifiHardwareEnabled: Networking.wifiHardwareEnabled
    readonly property var connectedWifiNetwork: networks.find(network => network.connected) || null
    readonly property bool wiredConnected: wiredDevice !== null && wiredDevice.connected

    property real downloadBytesPerSecond: 0
    property real uploadBytesPerSecond: 0
    property bool trafficReady: false
    property real lastReceivedBytes: 0
    property real lastTransmittedBytes: 0
    property real lastSampleTime: 0
    property string lastDeviceKey: ""
    property string pendingDeviceKey: ""

    property Process trafficProcess: Process {
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyTrafficSample(text)
        }
        onExited: exitCode => {
            if (exitCode !== 0)
                root.resetTraffic();
        }
    }

    property Timer trafficTimer: Timer {
        interval: 1000
        repeat: true
        running: SettingsPanelService.screenName.length > 0
            && SettingsPanelService.section === "network"
        triggeredOnStart: true
        onRunningChanged: {
            if (!running)
                root.resetTraffic();
        }
        onTriggered: root.sampleTraffic()
    }

    function findDevice(type) {
        let fallback = null;
        for (const device of devices) {
            if (!device || device.type !== type)
                continue;
            if (device.connected)
                return device;
            if (!fallback)
                fallback = device;
        }
        return fallback;
    }

    function sortedNetworks() {
        const unique = {};
        for (const network of networkObjects) {
            if (!network || !network.name)
                continue;
            const previous = unique[network.name];
            if (!previous || network.connected || network.signalStrength > previous.signalStrength)
                unique[network.name] = network;
        }

        return Object.values(unique).sort((left, right) => {
            if (left.connected !== right.connected)
                return left.connected ? -1 : 1;
            if (left.known !== right.known)
                return left.known ? -1 : 1;
            return right.signalStrength - left.signalStrength;
        });
    }

    function connectedDeviceNames(): var {
        const names = [];
        for (const device of devices) {
            if (device && device.connected
                    && (device.type === DeviceType.Wifi || device.type === DeviceType.Wired))
                names.push(device.name);
        }
        return names.sort();
    }

    function sampleTraffic(): void {
        if (trafficProcess.running)
            return;
        const names = connectedDeviceNames();
        if (names.length === 0) {
            resetTraffic();
            trafficReady = true;
            return;
        }
        pendingDeviceKey = names.join("\n");
        trafficProcess.command = [
            "sh", "-c",
            "rx=0; tx=0; for interface do "
                + "rx_file=\"/sys/class/net/$interface/statistics/rx_bytes\"; "
                + "tx_file=\"/sys/class/net/$interface/statistics/tx_bytes\"; "
                + "[ -r \"$rx_file\" ] || continue; "
                + "read -r value < \"$rx_file\" || continue; rx=$((rx + value)); "
                + "read -r value < \"$tx_file\" || continue; tx=$((tx + value)); "
                + "done; printf '%s %s\\n' \"$rx\" \"$tx\"",
            "kestrel-network-traffic"
        ].concat(names);
        trafficProcess.running = true;
    }

    function applyTrafficSample(output: string): void {
        if (!trafficTimer.running) {
            resetTraffic();
            return;
        }
        const fields = output.trim().split(/\s+/);
        const received = fields.length === 2 ? Number(fields[0]) : NaN;
        const transmitted = fields.length === 2 ? Number(fields[1]) : NaN;
        if (!Number.isFinite(received) || !Number.isFinite(transmitted)) {
            resetTraffic();
            return;
        }

        const now = Date.now();
        if (lastDeviceKey === pendingDeviceKey && lastSampleTime > 0
                && received >= lastReceivedBytes
                && transmitted >= lastTransmittedBytes) {
            const elapsedSeconds = (now - lastSampleTime) / 1000;
            if (elapsedSeconds > 0) {
                downloadBytesPerSecond = (received - lastReceivedBytes) / elapsedSeconds;
                uploadBytesPerSecond = (transmitted - lastTransmittedBytes) / elapsedSeconds;
                trafficReady = true;
            }
        } else {
            trafficReady = false;
        }

        lastReceivedBytes = received;
        lastTransmittedBytes = transmitted;
        lastSampleTime = now;
        lastDeviceKey = pendingDeviceKey;
    }

    function resetTraffic(): void {
        downloadBytesPerSecond = 0;
        uploadBytesPerSecond = 0;
        trafficReady = false;
        lastReceivedBytes = 0;
        lastTransmittedBytes = 0;
        lastSampleTime = 0;
        lastDeviceKey = "";
        pendingDeviceKey = "";
    }

    function formatRate(bytesPerSecond: real): string {
        const units = ["B/s", "KiB/s", "MiB/s", "GiB/s"];
        let value = Math.max(0, bytesPerSecond);
        let unit = 0;
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024;
            unit += 1;
        }
        const digits = value >= 100 || unit === 0 ? 0 : (value >= 10 ? 1 : 2);
        return value.toFixed(digits) + " " + units[unit];
    }

    function toggleWifi(): void {
        if (available && wifiHardwareEnabled)
            Networking.wifiEnabled = !Networking.wifiEnabled;
    }

    function connectWired(): void {
        if (wiredNetwork && !wiredNetwork.connected)
            wiredNetwork.connect();
    }

    function toggleWired(): void {
        if (!wiredNetwork)
            return;
        if (wiredNetwork.connected)
            wiredNetwork.disconnect();
        else
            wiredNetwork.connect();
    }

    function isOpen(network): bool {
        return network && (network.security === WifiSecurityType.Open || network.security === WifiSecurityType.Owe);
    }

    function activate(network): bool {
        if (!network)
            return true;
        if (network.connected) {
            network.disconnect();
            return true;
        }
        if (network.known || isOpen(network)) {
            network.connect();
            return true;
        }
        return false;
    }

    function connectWithPassword(network, password: string): void {
        if (network && password.length > 0)
            network.connectWithPsk(password);
    }
}
