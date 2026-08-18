pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    readonly property var applications: DesktopEntries.applications.values
    property var usage: ({})
    property bool historyLoaded: false

    property FileView historyFile: FileView {
        path: StandardPaths.writableLocation(StandardPaths.GenericStateLocation)
            + "/kestrel/launcher-history.json"
        blockLoading: true
        blockWrites: true
        watchChanges: false

        onLoaded: root.loadHistory(text())

        onLoadFailed: root.historyLoaded = true
    }

    function loadHistory(contents: string): void {
        try {
            const parsed = JSON.parse(contents || "{}");
            usage = parsed.usage || {};
        } catch (error) {
            usage = {};
        }
        historyLoaded = true;
    }

    function saveHistory(): void {
        if (!historyLoaded)
            return;
        historyFile.setText(JSON.stringify({ "usage": usage }, null, 2));
    }

    function normalize(value): string {
        return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    }

    function usageScore(app): real {
        const record = usage[app.id];
        if (!record)
            return 0;
        const ageDays = Math.max(0, (Date.now() - (record.lastUsed || 0)) / 86400000);
        const recency = Math.max(0, 120 - ageDays * 4);
        return Math.log((record.count || 0) + 1) * 80 + recency;
    }

    function subsequenceScore(needle: string, haystack: string): real {
        let position = -1;
        let gaps = 0;
        for (let index = 0; index < needle.length; index += 1) {
            const next = haystack.indexOf(needle[index], position + 1);
            if (next < 0)
                return -1;
            if (position >= 0)
                gaps += next - position - 1;
            position = next;
        }
        return 1000 - gaps * 8 - position;
    }

    function matchScore(app, query: string): real {
        const needle = normalize(query);
        if (needle.length === 0)
            return usageScore(app);

        const name = normalize(app.name);
        const genericName = normalize(app.genericName);
        const keywords = normalize((app.keywords || []).join(" "));
        const comment = normalize(app.comment);
        const searchable = [name, genericName, keywords, comment].join(" ");
        const tokens = needle.split(" ").filter(token => token.length > 0);
        if (!tokens.every(token => searchable.includes(token))) {
            const compactNeedle = needle.replace(/ /g, "");
            const compactName = name.replace(/ /g, "");
            const fuzzy = subsequenceScore(compactNeedle, compactName);
            return fuzzy < 0 ? -1 : fuzzy + usageScore(app) * 0.05;
        }

        let score = 3000;
        if (name === needle)
            score = 10000;
        else if (name.startsWith(needle))
            score = 8000 - name.length;
        else if (name.split(" ").some(word => word.startsWith(needle)))
            score = 6500;
        else if (name.includes(needle))
            score = 5000;
        else if (tokens.every(token => name.split(" ").some(word => word.startsWith(token))))
            score = 4200;

        return score + usageScore(app) * 0.05;
    }

    function results(query: string, limit: int): var {
        const seen = new Set();
        const matches = [];
        for (const app of applications) {
            if (!app || !app.id || seen.has(app.id))
                continue;
            seen.add(app.id);
            const score = matchScore(app, query);
            if (score >= 0)
                matches.push({ "app": app, "score": score });
        }

        matches.sort((left, right) => {
            if (left.score !== right.score)
                return right.score - left.score;
            const leftUsed = root.usage[left.app.id]?.lastUsed || 0;
            const rightUsed = root.usage[right.app.id]?.lastUsed || 0;
            if (leftUsed !== rightUsed)
                return rightUsed - leftUsed;
            return left.app.name.localeCompare(right.app.name);
        });
        return matches.slice(0, Math.max(1, limit)).map(match => match.app);
    }

    function open(targetScreen: string): void {
        ClockPanelService.close();
        BarModeService.open("launcher", targetScreen, true);
    }

    function toggle(targetScreen: string): void {
        if (BarModeService.activeMode === "launcher"
                && BarModeService.screenName === targetScreen) {
            BarModeService.close();
        } else {
            open(targetScreen);
        }
    }

    function launch(app): void {
        if (!app)
            return;
        const nextUsage = Object.assign({}, usage);
        const record = nextUsage[app.id] || { "count": 0, "lastUsed": 0 };
        nextUsage[app.id] = {
            "count": record.count + 1,
            "lastUsed": Date.now()
        };
        usage = nextUsage;
        saveHistory();
        BarModeService.close();
        app.execute();
    }
}
