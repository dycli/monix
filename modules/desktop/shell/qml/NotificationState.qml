pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland
import Quickshell.Services.Notifications

QtObject {
    id: root

    property var liveRefs: ({})
    property var tickerQueue: []
    property var currentTicker: null
    property int tickerGeneration: 0
    property string tickerScreenName: ""
    property ListModel historyModel: ListModel {}

    readonly property int historyLimit: 50

    property NotificationServer server: NotificationServer {
        actionsSupported: true
        bodyMarkupSupported: false
        bodyHyperlinksSupported: false
        imageSupported: false
        persistenceSupported: false

        onNotification: notification => root.receive(notification)
    }

    function plainText(value): string {
        return String(value || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
    }

    function receive(notification): void {
        notification.tracked = true;
        const row = {
            id: notification.id,
            app: plainText(notification.appName) || "Notification",
            summary: plainText(notification.summary),
            body: plainText(notification.body),
            timestamp: Date.now(),
            urgency: notification.urgency
        };

        liveRefs[row.id] = notification;
        notification.closed.connect(() => {
            if (root.liveRefs[row.id] === notification)
                delete root.liveRefs[row.id];
        });

        removeHistoryId(row.id);
        historyModel.insert(0, row);
        while (historyModel.count > historyLimit)
            historyModel.remove(historyModel.count - 1);

        tickerQueue = tickerQueue.concat([row]);
        if (!currentTicker)
            showNextTicker();
    }

    function removeHistoryId(id): void {
        for (let index = historyModel.count - 1; index >= 0; index -= 1) {
            if (historyModel.get(index).id === id)
                historyModel.remove(index);
        }
    }

    function showNextTicker(): void {
        if (tickerQueue.length === 0) {
            currentTicker = null;
            return;
        }
        currentTicker = tickerQueue[0];
        tickerQueue = tickerQueue.slice(1);
        tickerScreenName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        tickerGeneration += 1;
    }

    function finishTicker(generation: int): void {
        if (!currentTicker || generation !== tickerGeneration)
            return;
        const ref = liveRefs[currentTicker.id];
        if (ref) {
            try {
                ref.expire();
            } catch (error) {
            }
        }
        currentTicker = null;
        Qt.callLater(showNextTicker);
    }

    function dismiss(index: int): void {
        if (index < 0 || index >= historyModel.count)
            return;
        const row = historyModel.get(index);
        const ref = liveRefs[row.id];
        if (ref) {
            try {
                ref.dismiss();
            } catch (error) {
            }
        }
        historyModel.remove(index);
    }

    function invokeDefault(index: int): void {
        if (index < 0 || index >= historyModel.count)
            return;
        const row = historyModel.get(index);
        const ref = liveRefs[row.id];
        if (ref) {
            try {
                const action = ref.actions.find(candidate => candidate.identifier === "default");
                if (action)
                    action.invoke();
            } catch (error) {
            }
        }
        dismiss(index);
    }

    function clear(): void {
        for (let index = historyModel.count - 1; index >= 0; index -= 1)
            dismiss(index);
    }
}
