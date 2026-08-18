pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Pipewire

QtObject {
    id: root

    readonly property bool microphoneActive: {
        if (!Pipewire.ready)
            return false;
        for (const node of Pipewire.nodes.values) {
            if (!node || (node.type & PwNodeType.AudioInStream) !== PwNodeType.AudioInStream)
                continue;
            if (isSystemMicrophone(node) || (node.audio && node.audio.muted))
                continue;
            return true;
        }
        return false;
    }

    readonly property bool cameraActive: {
        if (!Pipewire.ready)
            return false;
        for (const node of Pipewire.nodes.values) {
            if (!node || !node.ready || !node.properties)
                continue;
            if (node.properties["media.class"] === "Stream/Input/Video"
                    && node.properties["stream.is-live"] === "true")
                return true;
        }
        return false;
    }

    readonly property bool screenSharingActive: {
        if (!Pipewire.ready)
            return false;
        for (const node of Pipewire.nodes.values) {
            if (!node || !node.ready)
                continue;
            const videoSource = (node.type & PwNodeType.VideoSource) === PwNodeType.VideoSource;
            const outputStream = node.properties
                && node.properties["media.class"] === "Stream/Output/Video";
            if ((videoSource || outputStream) && isScreenCast(node))
                return true;
        }
        return false;
    }

    readonly property bool active: microphoneActive || cameraActive || screenSharingActive

    property PwObjectTracker tracker: PwObjectTracker {
        objects: Pipewire.nodes.values.filter(node => !node.isStream)
    }

    function nodeDescription(node): string {
        if (!node)
            return "";
        const properties = node.properties || {};
        return [node.name, properties["media.name"], properties["application.name"]]
            .join(" ").toLowerCase();
    }

    function isSystemMicrophone(node): bool {
        return /cava|monitor|system/.test(nodeDescription(node));
    }

    function isScreenCast(node): bool {
        return /xdg-desktop-portal|xdpw|screencast|screen-cast|screen|obs/.test(
            nodeDescription(node));
    }
}
