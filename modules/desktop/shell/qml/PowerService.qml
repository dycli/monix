pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower

QtObject {
    id: root

    readonly property var batteries: UPower.devices.values.filter(device => device.isLaptopBattery && device.ready && device.isPresent)
    readonly property var device: batteries[0] || null
    readonly property bool hasBattery: device !== null
    readonly property int percentage: hasBattery ? Math.round(device.percentage * 100) : 0
    readonly property bool charging: hasBattery && device.state === UPowerDeviceState.Charging
    readonly property bool full: hasBattery && (device.state === UPowerDeviceState.FullyCharged || percentage >= 100)
    readonly property bool pluggedIn: !UPower.onBattery
    readonly property bool profilesAvailable: typeof PowerProfiles !== "undefined"
    readonly property var availableProfiles: [PowerProfile.PowerSaver, PowerProfile.Balanced].concat(
        profilesAvailable && PowerProfiles.hasPerformanceProfile ? [PowerProfile.Performance] : []
    )

    property bool idleInhibited: false

    readonly property string status: {
        if (!hasBattery)
            return "AC Power";

        switch (device.state) {
        case UPowerDeviceState.Charging:
            return "Charging";
        case UPowerDeviceState.Discharging:
            return "Discharging";
        case UPowerDeviceState.Empty:
            return "Empty";
        case UPowerDeviceState.FullyCharged:
            return "Fully Charged";
        case UPowerDeviceState.PendingCharge:
            return "Plugged In";
        case UPowerDeviceState.PendingDischarge:
            return "Pending Discharge";
        default:
            return pluggedIn ? "Plugged In" : "Unknown";
        }
    }

    readonly property string health: hasBattery && device.healthSupported
        ? Math.round(device.healthPercentage) + "%"
        : "Unknown"
    readonly property string capacity: hasBattery && device.energyCapacity > 0
        ? device.energyCapacity.toFixed(1) + " Wh"
        : "Unknown"
    readonly property string rate: {
        if (!hasBattery || device.changeRate <= 0)
            return "—";
        return (charging ? "+" : "−") + device.changeRate.toFixed(1) + " W";
    }
    readonly property string time: {
        if (!hasBattery || full)
            return full ? "Full" : "Unknown";
        const seconds = charging ? device.timeToFull : device.timeToEmpty;
        if (!seconds || seconds <= 0 || seconds > 86400)
            return "Unknown";
        const hours = Math.floor(seconds / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        return hours > 0 ? hours + "h " + minutes + "m" : minutes + "m";
    }

    function profileName(profile): string {
        switch (profile) {
        case PowerProfile.PowerSaver:
            return "Saver";
        case PowerProfile.Balanced:
            return "Balanced";
        case PowerProfile.Performance:
            return "Performance";
        default:
            return "Unknown";
        }
    }

    function setProfile(profile): void {
        if (profilesAvailable && availableProfiles.indexOf(profile) !== -1)
            PowerProfiles.profile = profile;
    }

    function cycleProfile(): void {
        if (!profilesAvailable)
            return;
        const index = availableProfiles.indexOf(PowerProfiles.profile);
        setProfile(availableProfiles[(index + 1) % availableProfiles.length]);
    }
}
