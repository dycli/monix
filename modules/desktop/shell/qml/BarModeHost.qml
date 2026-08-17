pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    required property string screenName

    readonly property bool active: BarModeService.isActive(screenName)

    implicitWidth: modeLoader.item ? modeLoader.item.implicitWidth : 0
    implicitHeight: 24
    visible: active

    Shortcut {
        enabled: root.active
        sequence: "Escape"
        onActivated: BarModeService.close()
    }

    Loader {
        id: modeLoader

        anchors {
            left: parent.left
            verticalCenter: parent.verticalCenter
        }
        sourceComponent: {
            if (!root.active)
                return null;
            switch (BarModeService.activeMode) {
            case "power":
                return powerMode;
            case "control":
                return controlMode;
            case "network":
                return networkMode;
            default:
                return null;
            }
        }
    }

    Component {
        id: powerMode

        PowerBarMenu {
            onCloseRequested: BarModeService.close()
        }
    }

    Component {
        id: controlMode

        ControlBarMenu {
            onCloseRequested: BarModeService.close()
            onModeRequested: mode => BarModeService.open(mode, root.screenName)
        }
    }

    Component {
        id: networkMode

        NetworkBarMenu {
            onBackRequested: BarModeService.open("control", root.screenName)
            onCloseRequested: BarModeService.close()
        }
    }
}
