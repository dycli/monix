pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower

// The right rail: a pinned block (media controls, tray, privacy, battery,
// settings, clock) and one popout that slides out to its left with everything else. The
// popout opens while the pointer is on the rail, when a key flashes a
// control, while the settings panel is open and when the battery is low.
Item {
    id: root

    required property string screenName
    required property real maximumWidth

    readonly property real gap: Style.barItemGap
    readonly property bool ownsMode: BarModeService.isActive(screenName)
    readonly property string transientMode: BarModeService.transientFor(screenName)
    readonly property bool transientVisible: BarModeService.transientVisibleFor(screenName)
    readonly property bool settingsOpen: SettingsPanelService.isOpen(screenName)
    readonly property bool lowBatteryOpen: PowerService.hasBattery
        && PowerService.percentage <= 15 && !PowerService.charging
    readonly property bool detailVisible: ownsMode && BarModeService.activeMode === "session"
    // A flash alone shows just the flashed control. transientMode outlives
    // transientVisible by the close animation, so the popout keeps its one
    // control while it slides away.
    readonly property string flashOnly: transientMode !== "" && !hoverOpen
        && !settingsOpen && !lowBatteryOpen ? transientMode : ""
    readonly property bool popoutVisible: !detailVisible && BarModeService.activeMode === ""
        && (hoverOpen || transientVisible || settingsOpen || lowBatteryOpen)
    readonly property real mediaLead: media.visible ? media.width + gap : 0
    readonly property real trayLead: tray.width > 0 ? tray.width + gap : 0
    readonly property real privacyLead: privacy.width > 0 ? privacy.width + gap : 0
    readonly property real pinnedControlsLead: pinnedControls.implicitWidth > 0
        ? pinnedControls.implicitWidth + gap : 0
    readonly property real idleWidth: mediaLead + trayLead + privacyLead + pinnedControlsLead
        + settingsButton.width + gap + clock.width
    readonly property real popoutRoom: Math.max(0, maximumWidth - idleWidth - gap)
    readonly property real popoutWidth: Math.min(popoutRoom, popout.implicitWidth)
    readonly property real popoutLead: popoutProgress * (popoutWidth + gap)
    readonly property real endControlWidth: sessionDetailVisual ? 0 : settingsButton.width
    readonly property real endControlGap: endControlWidth > 0 ? gap : 0
    readonly property real detailContentWidth: Math.min(sessionMenu.implicitWidth, Math.max(0,
        maximumWidth - pinnedControlsLead - endControlWidth - endControlGap))
    readonly property real detailWidth: pinnedControlsLead + detailContentWidth
        + endControlGap + endControlWidth
    readonly property real restingWidth: idleWidth + popoutLead

    property bool hoverOpen: false
    property bool sessionDetailVisual: false
    property real popoutProgress: popoutVisible ? 1 : 0
    property real detailProgress: detailVisible ? 1 : 0

    function closeOthers(): void {
        hoverOpen = false;
        SystemMenuService.close();
        ToolsMenuService.close();
        ViewMenuService.close();
        LauncherService.close();
        BarModeService.close();
        ClockPanelService.close();
        ClipboardPanelService.close();
    }

    width: restingWidth + detailProgress * (detailWidth - restingWidth)
    height: 28
    clip: true

    onDetailVisibleChanged: {
        if (detailVisible)
            sessionDetailVisual = true;
    }

    onDetailProgressChanged: {
        if (!detailVisible && detailProgress <= 0)
            sessionDetailVisual = false;
    }

    Behavior on popoutProgress {
        NumberAnimation { duration: 170; easing.type: Easing.OutCubic }
    }

    Behavior on detailProgress {
        NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
    }

    HoverHandler {
        id: railHover

        onHoveredChanged: {
            if (hovered) {
                hoverCloseTimer.stop();
                if (!root.detailVisible && BarModeService.activeMode === "")
                    root.hoverOpen = true;
            } else {
                hoverCloseTimer.restart();
            }
        }
    }

    Timer {
        id: hoverCloseTimer

        interval: 1000
        onTriggered: {
            if (!railHover.hovered)
                root.hoverOpen = false;
        }
    }

    Shortcut {
        enabled: root.ownsMode
        sequence: "Escape"
        onActivated: BarModeService.close()
    }

    Item {
        id: popoutViewport

        anchors.verticalCenter: parent.verticalCenter
        x: media.x - root.gap - width
        width: root.popoutWidth
        height: 24
        clip: true
        enabled: root.popoutVisible

        Row {
            id: popout

            readonly property real fixedWidth: controlMenu.implicitWidth
                + (powerOverview.visible ? root.gap + powerOverview.implicitWidth : 0)

            anchors.verticalCenter: parent.verticalCenter
            x: parent.width - width + parent.width * (1 - root.popoutProgress)
            height: 24
            spacing: root.gap

            MediaTitle {
                visible: root.flashOnly === "" && MediaState.available && text.length > 0
                    && width > 0
                maximumWidth: Math.max(0, root.popoutRoom - popout.fixedWidth - root.gap)
            }

            ControlBarMenu {
                id: controlMenu

                visible: root.flashOnly !== "profile"
                only: root.flashOnly
                settingsOpen: root.settingsOpen
                onSettingsRequested: section => {
                    root.closeOthers();
                    SettingsPanelService.openSection(root.screenName, section);
                }
                onDisplayRequested: {
                    root.closeOthers();
                    SettingsPanelService.openDisplay(root.screenName);
                }
            }

            PowerOverviewCarousel {
                id: powerOverview

                generation: BarModeService.transientGeneration
                mode: root.transientVisible && root.transientMode === "profile"
                    ? "profile" : "battery"
                profileLabel: PowerService.profilesAvailable
                    ? PowerService.profileName(PowerProfiles.profile) : "Power"
                visible: PowerService.hasBattery
                    && (root.flashOnly === "" || root.flashOnly === "profile")

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.closeOthers();
                        SettingsPanelService.openPower(root.screenName);
                    }
                }
            }
        }
    }

    MediaBar {
        id: media

        anchors.verticalCenter: parent.verticalCenter
        x: root.popoutLead - root.detailProgress * (width + root.gap + root.popoutLead)
        enabled: !root.detailVisible
        opacity: 1 - root.detailProgress
        visible: MediaState.available && width > 0
    }

    SystemTrayView {
        id: tray

        anchors.verticalCenter: parent.verticalCenter
        x: media.x + root.mediaLead
        enabled: !root.detailVisible
        opacity: 1 - root.detailProgress
    }

    PrivacyIndicator {
        id: privacy

        anchors.verticalCenter: parent.verticalCenter
        x: tray.x + root.trayLead
        opacity: 1 - root.detailProgress
    }

    PinnedControlItems {
        id: pinnedControls

        anchors.verticalCenter: parent.verticalCenter
        x: (root.popoutLead + root.mediaLead + root.trayLead + root.privacyLead)
            * (1 - root.detailProgress)
        onPowerActivated: {
            root.closeOthers();
            SettingsPanelService.openPower(root.screenName);
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

        SessionBarMenu {
            id: sessionMenu

            active: root.detailVisible
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            visible: root.sessionDetailVisual
        }
    }

    SettingsButton {
        id: settingsButton

        anchors.verticalCenter: parent.verticalCenter
        x: root.width - clock.width - root.gap - width
            + root.detailProgress * (clock.width + root.gap + width + root.gap)
        onMenuToggleRequested: {
            root.closeOthers();
            SettingsPanelService.toggle(root.screenName);
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
            SystemMenuService.close();
            ToolsMenuService.close();
            ViewMenuService.close();
            LauncherService.close();
            BarModeService.close();
            ClipboardPanelService.close();
            SettingsPanelService.close();
            ClockPanelService.toggle(root.screenName);
        }
    }

    ClockPopout {
        anchorItem: clock
        screenName: root.screenName
    }

    SettingsPopout {
        anchorItem: settingsButton
        screenName: root.screenName
    }
}
