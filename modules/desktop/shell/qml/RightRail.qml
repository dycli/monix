pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower

Item {
    id: root

    required property string screenName
    required property real maximumWidth

    readonly property real gap: Style.barItemGap
    readonly property bool ownsMode: BarModeService.isActive(screenName)
    readonly property string transientMode: BarModeService.transientFor(screenName)
    readonly property bool transientVisible: BarModeService.transientVisibleFor(screenName)
    readonly property string requestedMode: ownsMode ? BarModeService.activeMode : ""
    readonly property bool controlDetail: ownsMode
        && (requestedMode === "network" || requestedMode === "bluetooth")
    readonly property bool sessionDetail: ownsMode && requestedMode === "session"
    readonly property bool clipboardDetail: ownsMode && requestedMode === "clipboard"
    readonly property bool detailVisible: controlDetail || sessionDetail || clipboardDetail
    readonly property bool sessionDetailVisual: displayedDetailMode === "session"
    readonly property bool overviewVisible: !detailVisible && BarModeService.activeMode === ""
        && (hoverOpen || transientVisible)
    readonly property string overviewMode: {
        if (transientVisible)
            return transientMode === "profile" || !hoverOpen ? transientMode : hoverMode;
        if (hoverOpen)
            return hoverMode;
        return transientMode !== "" ? transientMode : hoverMode;
    }
    readonly property bool powerAnchoredOverview: overviewMode === "battery"
        || overviewMode === "profile"
    readonly property bool pinned: ownsMode
    readonly property real trayLead: tray.width > 0 ? tray.width + gap : 0

    property bool hoverOpen: false
    property string hoverMode: "control"
    property string displayedDetailMode: ""
    property real overviewProgress: overviewVisible ? 1 : 0
    property real detailProgress: detailVisible ? 1 : 0

    readonly property real idleWidth: trayLead + powerButton.width + gap + settingsButton.width
        + gap + clock.width
    readonly property real overviewWidth: Math.min(maximumWidth,
        idleWidth + gap + overviewContent.implicitWidth)
    readonly property real endControlWidth: sessionDetailVisual
        ? 0
        : (detailEndLoader.item ? detailEndLoader.item.implicitWidth : settingsButton.width)
    readonly property real endControlGap: endControlWidth > 0 ? gap : 0
    readonly property real selectedStatusStartX: controlDetail
        ? trayLead + powerButton.width + gap
            + (displayedDetailMode === "bluetooth" ? controlMenu.bluetoothItemX : controlMenu.networkItemX)
        : settingsButton.x
    readonly property real availableDetailWidth: Math.max(0,
        maximumWidth - endControlWidth - endControlGap)
    readonly property real requestedDetailWidth: detailLoader.item
        ? detailLoader.item.implicitWidth : controlMenu.implicitWidth
    readonly property real detailContentWidth: Math.min(availableDetailWidth, requestedDetailWidth)
    readonly property real detailWidth: detailContentWidth + endControlGap + endControlWidth
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
            if (!hovered)
                root.hoverOpen = false;
        }
    }

    Shortcut {
        enabled: root.pinned
        sequence: "Escape"
        onActivated: BarModeService.close()
    }

    SystemTrayView {
        id: tray

        anchors.verticalCenter: parent.verticalCenter
        x: -root.detailProgress * (width + root.gap)
        enabled: !root.detailVisible
        opacity: 1 - root.detailProgress
    }

    Power {
        id: powerButton

        anchors.verticalCenter: parent.verticalCenter
        x: {
            const previewOffset = root.powerAnchoredOverview
                ? root.overviewProgress * (root.gap + overviewContent.implicitWidth)
                : 0;
            const start = root.trayLead + previewOffset;
            return start + root.detailProgress * (-width - root.gap - start);
        }
        onHoveredChanged: {
            if (hovered && PowerService.hasBattery && !root.detailVisible
                    && BarModeService.activeMode === "") {
                root.hoverMode = "battery";
                root.hoverOpen = true;
            }
        }
    }

    Item {
        id: overviewViewport

        anchors.verticalCenter: parent.verticalCenter
        x: (root.powerAnchoredOverview ? powerButton.x : settingsButton.x)
            - root.gap - width
        width: overviewContent.implicitWidth * root.overviewProgress * (1 - root.detailProgress)
        height: 24
        clip: true
        enabled: root.overviewVisible

        Item {
            id: overviewContent

            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            width: implicitWidth
            height: implicitHeight
            implicitWidth: {
                switch (root.overviewMode) {
                case "battery": return powerOverview.implicitWidth;
                case "volume": return volumeOsd.implicitWidth;
                case "brightness": return brightnessOsd.implicitWidth;
                case "microphone": return microphoneOsd.implicitWidth;
                case "profile": return powerOverview.implicitWidth;
                case "inhibit": return inhibitOsd.implicitWidth;
                default: return controlMenu.implicitWidth;
                }
            }
            implicitHeight: 24

            ControlBarMenu {
                id: controlMenu

                anchors.right: parent.right
                visible: root.overviewMode === "control"
                onModeRequested: mode => {
                    root.hoverOpen = false;
                    ClockPanelService.close();
                    BarModeService.open(mode, root.screenName, false);
                }
            }

            PowerOverviewCarousel {
                id: powerOverview

                anchors.right: parent.right
                generation: BarModeService.transientGeneration
                mode: root.overviewMode === "profile" ? "profile" : "battery"
                profileLabel: PowerService.profilesAvailable
                    ? PowerService.profileName(PowerProfiles.profile) : "Power"
                visible: root.overviewMode === "battery" || root.overviewMode === "profile"
            }

            BarSlider {
                id: volumeOsd

                anchors.right: parent.right
                available: AudioState.available
                icon: AudioState.icon
                value: AudioState.volume / 100
                visible: root.overviewMode === "volume"
                onMoved: value => {
                    AudioState.setVolume(value);
                    BarModeService.flash("volume", root.screenName);
                }
                onSecondaryActivated: {
                    AudioState.toggleMute();
                    BarModeService.flash("volume", root.screenName);
                }
            }

            BarSlider {
                id: brightnessOsd

                anchors.right: parent.right
                available: BrightnessState.available
                icon: BrightnessState.icon
                value: BrightnessState.level
                visible: root.overviewMode === "brightness"
                onMoved: value => {
                    BrightnessState.setLevel(value);
                    BarModeService.flash("brightness", root.screenName);
                }
            }

            BarModeButton {
                id: microphoneOsd

                anchors.right: parent.right
                enabled: AudioState.sourceAvailable
                icon: AudioState.sourceIcon
                label: AudioState.sourceMuted ? "Muted" : "Live"
                visible: root.overviewMode === "microphone"
                onActivated: {
                    AudioState.toggleSourceMute();
                    BarModeService.flash("microphone", root.screenName);
                }
            }

            BarModeButton {
                id: inhibitOsd

                anchors.right: parent.right
                icon: ""
                label: PowerService.idleInhibited ? "Inhibited" : "Idle enabled"
                visible: root.overviewMode === "inhibit"
                interactive: false
            }
        }
    }

    Item {
        id: detailViewport

        anchors.verticalCenter: parent.verticalCenter
        x: root.width - root.endControlWidth - root.endControlGap - width
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
                case "session":
                    return sessionMode;
                case "clipboard":
                    return clipboardMode;
                default:
                    return null;
                }
            }
        }
    }

    Loader {
        id: detailEndLoader

        anchors.verticalCenter: parent.verticalCenter
        x: root.selectedStatusStartX + root.detailProgress
            * (root.width - width - root.selectedStatusStartX)
        enabled: root.detailVisible
        opacity: root.detailProgress
        sourceComponent: {
            switch (root.displayedDetailMode) {
            case "network":
                return networkEndMode;
            case "bluetooth":
                return bluetoothEndMode;
            case "clipboard":
                return clipboardEndMode;
            default:
                return null;
            }
        }
    }

    SettingsButton {
        id: settingsButton

        anchors.verticalCenter: parent.verticalCenter
        x: root.width - clock.width - root.gap - width
            + root.detailProgress * (clock.width + root.gap + width + root.gap)
        onHoveredChanged: {
            if (hovered && !root.detailVisible && BarModeService.activeMode === "") {
                root.hoverMode = "control";
                root.hoverOpen = true;
            }
        }
        onMenuToggleRequested: {
            ClockPanelService.close();
            if (!root.detailVisible && BarModeService.activeMode === "")
                root.hoverOpen = true;
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
        id: sessionMode

        SessionBarMenu {}
    }

    Component {
        id: clipboardMode

        ClipboardBarMenu {}
    }

    Component {
        id: networkEndMode

        NetworkStatusButton {
            onDetailRequested: {
                if (!NetworkState.wifiEnabled && NetworkState.wifiDevice !== null)
                    NetworkState.toggleWifi();
                else
                    BarModeService.close();
            }
        }
    }

    Component {
        id: bluetoothEndMode

        BluetoothStatusButton {
            onDetailRequested: {
                if (!BluetoothState.enabled)
                    BluetoothState.toggleEnabled();
                else
                    BarModeService.close();
            }
        }
    }

    Component {
        id: clipboardEndMode

        BarModeButton {
            icon: ""
            onActivated: BarModeService.close()
        }
    }
}
