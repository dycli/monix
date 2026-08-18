pragma ComponentBehavior: Bound

import QtQuick

Row {
    height: 24
    spacing: 4

    BarModeButton {
        icon: ""
        label: "Lock"
        onActivated: SessionService.lock()
    }

    BarModeButton {
        icon: "󰤄"
        label: "Suspend"
        onActivated: SessionService.suspend()
    }

    BarModeButton {
        icon: "󰍃"
        label: "Logout"
        onActivated: SessionService.logout()
    }

    BarModeButton {
        icon: "󰜉"
        label: "Reboot"
        onActivated: SessionService.reboot()
    }

    BarModeButton {
        icon: ""
        label: "Off"
        onActivated: SessionService.powerOff()
    }
}
