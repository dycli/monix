pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick

QtObject {
    id: root

    property BrightnessDevice internal: BrightnessDevice {
        backend: "backlight"
    }

    property BrightnessDevice external: BrightnessDevice {
        backend: "ddc"
        displayNumber: 1
    }

    readonly property bool internalAvailable: internal.available
    readonly property bool externalAvailable: external.available
    readonly property real internalLevel: internal.level
    readonly property real externalLevel: external.level
    readonly property string internalIcon: internal.icon
    readonly property string externalIcon: external.icon

    readonly property bool available: internalAvailable || externalAvailable
    readonly property real level: internalAvailable ? internalLevel : externalLevel
    readonly property string icon: internalAvailable ? internalIcon : externalIcon

    function setLevel(value: real): void {
        if (internalAvailable)
            internal.setLevel(value);
        else
            external.setLevel(value);
    }

    function setInternalLevel(value: real): void {
        internal.setLevel(value);
    }

    function setExternalLevel(value: real): void {
        external.setLevel(value);
    }

    function refresh(): void {
        internal.refresh();
        external.refresh();
    }
}
