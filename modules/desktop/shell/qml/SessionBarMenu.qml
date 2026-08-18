pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    height: 24
    spacing: Style.barItemGap
    focus: true

    Component.onCompleted: Qt.callLater(() => forceActiveFocus())

    Keys.onPressed: event => {
        if (event.isAutoRepeat || event.modifiers !== Qt.NoModifier)
            return;
        switch (event.key) {
        case Qt.Key_L:
            SessionService.lock();
            break;
        case Qt.Key_S:
            SessionService.suspend();
            break;
        case Qt.Key_H:
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
        onActivated: SessionService.suspend()
    }

    BarModeButton {
        icon: ""
        label: "Hibernate"
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
        label: "Off"
        onActivated: SessionService.powerOff()
    }
}
