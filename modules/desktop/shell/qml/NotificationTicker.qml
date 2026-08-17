pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    required property string screenName

    readonly property bool ownsTicker: NotificationState.currentTicker !== null
        && (NotificationState.tickerScreenName.length === 0
            || NotificationState.tickerScreenName === screenName)
    readonly property int generation: NotificationState.tickerGeneration
    readonly property var ticker: ownsTicker ? NotificationState.currentTicker : null

    visible: ownsTicker

    onGenerationChanged: {
        if (ownsTicker)
            tickerAnimation.restart();
    }

    Text {
        id: tickerText

        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: {
            if (!root.ticker)
                return "";
            const detail = root.ticker.body ? " — " + root.ticker.body : "";
            return root.ticker.app + "  " + root.ticker.summary + detail;
        }
        x: parent.width
    }

    NumberAnimation {
        id: tickerAnimation

        target: tickerText
        property: "x"
        from: root.width
        to: -tickerText.implicitWidth
        duration: Math.max(5000, Math.round((root.width + tickerText.implicitWidth) / 80 * 1000))
        onFinished: NotificationState.finishTicker(root.generation)
    }
}
