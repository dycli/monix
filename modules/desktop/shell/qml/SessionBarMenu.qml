pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Row {
    id: root

    required property bool active

    readonly property bool sleepAllowed: Quickshell.env("KESTREL_ALLOW_SLEEP") === "true"

    height: 24
    spacing: Style.barItemGap
    focus: active

    onActiveChanged: {
        if (active)
            Qt.callLater(() => forceActiveFocus());
    }

    Keys.onPressed: event => {
        if (event.isAutoRepeat || event.modifiers !== Qt.NoModifier)
            return;
        switch (event.key) {
        case Qt.Key_L:
            SessionService.lock();
            break;
        case Qt.Key_S:
            if (!root.sleepAllowed)
                return;
            SessionService.suspend();
            break;
        case Qt.Key_H:
            if (!root.sleepAllowed)
                return;
            SessionService.hibernate();
            break;
        case Qt.Key_X:
            SessionService.logout();
            break;
        case Qt.Key_R:
            SessionService.reboot();
            break;
        case Qt.Key_P:
            SessionService.powerOff();
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    BarModeButton {
        icon: ""
        label: "Lock"
        onActivated: SessionService.lock()
    }

    BarModeButton {
        icon: "󰤄"
        label: "Suspend"
        visible: root.sleepAllowed
        onActivated: SessionService.suspend()
    }

    BarModeButton {
        icon: ""
        label: "Hibernate"
        visible: root.sleepAllowed
        onActivated: SessionService.hibernate()
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
        label: "Poweroff"
        onActivated: SessionService.powerOff()
    }
}
