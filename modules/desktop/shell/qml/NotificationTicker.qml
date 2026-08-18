pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Notifications

Item {
    id: root

    required property string screenName

    readonly property bool ownsTicker: NotificationState.currentTicker !== null
        && NotificationState.tickerScreenName === screenName
    readonly property int generation: NotificationState.tickerGeneration
    readonly property var ticker: ownsTicker ? NotificationState.currentTicker : null
    readonly property real contentLeft: tickerText.x
    readonly property real contentRight: tickerText.x + tickerText.implicitWidth
    readonly property real pixelsPerSecond: {
        if (!ticker)
            return 80;
        switch (ticker.urgency) {
        case NotificationUrgency.Low:
            return 100;
        case NotificationUrgency.Critical:
            return 60;
        default:
            return 80;
        }
    }
    property int runGeneration: 0

    visible: ownsTicker

    function startTicker(): void {
        if (!ownsTicker) {
            tickerAnimation.stop();
            return;
        }
        runGeneration = generation;
        tickerAnimation.restart();
    }

    onGenerationChanged: startTicker()
    onOwnsTickerChanged: startTicker()

    Text {
        id: tickerText

        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: root.ticker && root.ticker.urgency === NotificationUrgency.Critical
                ? 700 : Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: {
            if (!root.ticker)
                return "";
            const detail = root.ticker.body ? " — " + root.ticker.body : "";
            const message = root.ticker.app + "  " + root.ticker.summary + detail;
            return message.length > 300 ? message.slice(0, 299) + "…" : message;
        }
        x: parent.width
    }

    NumberAnimation {
        id: tickerAnimation

        target: tickerText
        property: "x"
        from: root.width
        to: -tickerText.implicitWidth
        duration: Math.max(5000, Math.round(
            (root.width + tickerText.implicitWidth) / root.pixelsPerSecond * 1000))
        onFinished: NotificationState.finishTicker(root.runGeneration)
    }
}
