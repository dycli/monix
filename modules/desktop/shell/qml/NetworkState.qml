pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Networking

QtObject {
    id: root

    readonly property bool available: Networking.backend === NetworkBackendType.NetworkManager
    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property var wifiDevice: findWifiDevice()
    readonly property var networkObjects: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
    readonly property var networks: sortedNetworks()
    readonly property var visibleNetworks: networks.slice(0, 6)

    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property bool wifiHardwareEnabled: Networking.wifiHardwareEnabled
    readonly property var connectedNetwork: networks.find(network => network.connected) || null

    function findWifiDevice() {
        let fallback = null;
        for (const device of devices) {
            if (!device || device.type !== DeviceType.Wifi)
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

    function toggleWifi(): void {
        if (available && wifiHardwareEnabled)
            Networking.wifiEnabled = !Networking.wifiEnabled;
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
