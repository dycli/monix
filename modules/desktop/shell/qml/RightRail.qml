pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    required property string screenName
    required property real maximumWidth

    readonly property real gap: 10
    readonly property bool ownsMode: BarModeService.isActive(screenName)
    readonly property bool pinnedOverview: ownsMode && BarModeService.activeMode === "control"
    readonly property bool controlDetail: ownsMode
        && (BarModeService.activeMode === "network" || BarModeService.activeMode === "bluetooth")
    readonly property bool powerDetail: ownsMode && BarModeService.activeMode === "power"
    readonly property bool detailVisible: controlDetail || powerDetail
    readonly property bool controlDetailVisual: displayedDetailMode === "network"
        || displayedDetailMode === "bluetooth"
    readonly property bool powerDetailVisual: displayedDetailMode === "power"
    readonly property bool overviewVisible: !detailVisible
        && (pinnedOverview || (hoverOpen && BarModeService.activeMode === ""))
    readonly property bool pinned: ownsMode

    property bool hoverOpen: false
    property string displayedDetailMode: ""
    property real overviewProgress: overviewVisible ? 1 : 0
    property real detailProgress: detailVisible ? 1 : 0

    readonly property real idleWidth: powerButton.width + gap + settingsButton.width
        + gap + clock.width
    readonly property real overviewWidth: Math.min(maximumWidth,
        idleWidth + gap + controlMenu.implicitWidth)
    readonly property real endControlWidth: powerDetailVisual ? powerButton.width : settingsButton.width
    readonly property real availableDetailWidth: Math.max(0, maximumWidth - endControlWidth - gap)
    readonly property real requestedDetailWidth: detailLoader.item
        ? detailLoader.item.implicitWidth : controlMenu.implicitWidth
    readonly property real detailContentWidth: Math.min(availableDetailWidth, requestedDetailWidth)
    readonly property real detailWidth: detailContentWidth + gap + endControlWidth
    readonly property real restingWidth: idleWidth
        + overviewProgress * (overviewWidth - idleWidth)
    readonly property real targetWidth: restingWidth
        + detailProgress * (detailWidth - restingWidth)

    width: targetWidth
    height: 28
    clip: true

    onDetailVisibleChanged: {
        if (detailVisible)
            displayedDetailMode = BarModeService.activeMode;
    }

    onDetailProgressChanged: {
        if (!detailVisible && detailProgress <= 0)
            displayedDetailMode = "";
    }

    Behavior on overviewProgress {
        NumberAnimation { duration: 170; easing.type: Easing.OutCubic }
    }

    Behavior on detailProgress {
        NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
    }

    HoverHandler {
        id: railHover

        onHoveredChanged: {
            if (!hovered && !root.pinnedOverview)
                root.hoverOpen = false;
        }
    }

    Shortcut {
        enabled: root.pinned
        sequence: "Escape"
        onActivated: BarModeService.close()
    }

    Power {
        id: powerButton

        anchors.verticalCenter: parent.verticalCenter
        scaleFactor: 1
        x: {
            if (root.powerDetailVisual)
                return root.detailProgress * (root.width - width);
            return -root.detailProgress * (width + root.gap);
        }
        onMenuToggleRequested: {
            root.hoverOpen = false;
            ClockPanelService.close();
            BarModeService.toggle("power", root.screenName);
        }
    }

    ControlBarMenu {
        id: controlMenu

        anchors.verticalCenter: parent.verticalCenter
        x: powerButton.width + root.gap
        enabled: root.overviewVisible
        opacity: root.overviewProgress * (1 - root.detailProgress)
        onModeRequested: mode => {
            root.hoverOpen = false;
            ClockPanelService.close();
            BarModeService.open(mode, root.screenName);
        }
    }

    Item {
        id: detailViewport

        anchors.verticalCenter: parent.verticalCenter
        x: root.width - root.endControlWidth - root.gap - width
        width: root.detailContentWidth
        height: 24
        clip: true
        enabled: root.detailVisible
        opacity: root.detailProgress

        Loader {
            id: detailLoader

            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            sourceComponent: {
                switch (root.displayedDetailMode) {
                case "network":
                    return networkMode;
                case "bluetooth":
                    return bluetoothMode;
                case "power":
                    return powerMode;
                default:
                    return null;
                }
            }
        }
    }

    SettingsButton {
        id: settingsButton

        anchors.verticalCenter: parent.verticalCenter
        x: root.width - clock.width - root.gap - width
            + root.detailProgress * (root.controlDetailVisual
                ? clock.width + root.gap
                : clock.width + root.gap + width + root.gap)
        onHoveredChanged: {
            if (hovered && !root.detailVisible
                    && (BarModeService.activeMode === "" || root.pinnedOverview))
                root.hoverOpen = true;
        }
        onMenuToggleRequested: {
            ClockPanelService.close();
            if (root.controlDetail) {
                BarModeService.open("control", root.screenName);
            } else if (root.pinnedOverview) {
                BarModeService.close();
            } else {
                BarModeService.open("control", root.screenName);
            }
        }
    }

    Clock {
        id: clock

        anchors.verticalCenter: parent.verticalCenter
        x: root.width - width + root.detailProgress * (width + root.gap)
        fontPixelSize: 10
        format: "ddd MMM d h:mm AP"
        onClicked: {
            root.hoverOpen = false;
            BarModeService.close();
            ClockPanelService.toggle(root.screenName);
        }
    }

    ClockPopout {
        anchorItem: clock
        screenName: root.screenName
    }

    Component {
        id: networkMode

        NetworkBarMenu {}
    }

    Component {
        id: bluetoothMode

        BluetoothBarMenu {}
    }

    Component {
        id: powerMode

        PowerBarMenu {}
    }
}
