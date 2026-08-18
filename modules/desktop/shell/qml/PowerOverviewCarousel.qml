pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    property string mode: "battery"
    property int generation: 0
    property string profileLabel: ""

    property bool initialized: false
    property bool syncScheduled: false
    property int activeSlot: 0
    property int nextSlot: 0

    readonly property string transitionKey: mode + ":" + (mode === "profile" ? generation : 0)
    readonly property var activeItem: activeSlot === 0 ? slotA : slotB
    readonly property var inactiveItem: activeSlot === 0 ? slotB : slotA

    implicitWidth: Math.max(batteryMeasure.implicitWidth, profileMeasure.implicitWidth)
    implicitHeight: 24
    width: implicitWidth
    height: implicitHeight
    clip: true

    function settle(): void {
        activeSlot = nextSlot;
        slotA.visible = activeSlot === 0;
        slotB.visible = activeSlot === 1;
        activeItem.x = width - activeItem.width;
    }

    function sync(initial: bool): void {
        const kind = mode === "profile" ? "profile" : "battery";
        const label = kind === "profile" ? profileLabel : "";

        if (!initialized || initial) {
            slotA.kind = kind;
            slotA.profileLabel = label;
            slotA.x = width - slotA.width;
            slotA.visible = true;
            slotB.visible = false;
            activeSlot = 0;
            nextSlot = 0;
            initialized = true;
            return;
        }

        if (carousel.running) {
            carousel.stop();
            settle();
        }

        const outgoing = activeItem;
        const incoming = inactiveItem;
        incoming.kind = kind;
        incoming.profileLabel = label;
        outgoing.x = width - outgoing.width;
        incoming.x = width;
        outgoing.visible = true;
        incoming.visible = true;
        nextSlot = activeSlot === 0 ? 1 : 0;

        outgoingAnimation.target = outgoing;
        outgoingAnimation.from = outgoing.x;
        outgoingAnimation.to = -outgoing.width;
        incomingAnimation.target = incoming;
        incomingAnimation.from = incoming.x;
        incomingAnimation.to = width - incoming.width;
        carousel.restart();
    }

    function scheduleSync(): void {
        if (!initialized || syncScheduled)
            return;
        syncScheduled = true;
        Qt.callLater(() => {
            syncScheduled = false;
            sync(false);
        });
    }

    onTransitionKeyChanged: scheduleSync()
    onWidthChanged: {
        if (initialized && !carousel.running)
            activeItem.x = width - activeItem.width;
    }
    Component.onCompleted: sync(true)

    PowerOverviewContent {
        id: slotA

        anchors.verticalCenter: parent.verticalCenter
    }

    PowerOverviewContent {
        id: slotB

        anchors.verticalCenter: parent.verticalCenter
        visible: false
    }

    BatteryBarStatus {
        id: batteryMeasure

        visible: false
    }

    BarModeButton {
        id: profileMeasure

        icon: "󰓅"
        interactive: false
        label: "Performance"
        visible: false
    }

    ParallelAnimation {
        id: carousel

        NumberAnimation {
            id: outgoingAnimation

            property: "x"
            duration: 170
            easing.type: Easing.InOutCubic
        }

        NumberAnimation {
            id: incomingAnimation

            property: "x"
            duration: 170
            easing.type: Easing.InOutCubic
        }

        onFinished: root.settle()
    }
}
