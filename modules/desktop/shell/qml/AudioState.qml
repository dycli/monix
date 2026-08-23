pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Pipewire

QtObject {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property var audioNodes: Pipewire.nodes.values.filter(node => node.audio)
    readonly property var outputStreams: audioNodes.filter(node => node.isStream && node.isSink)
    readonly property var inputStreams: audioNodes.filter(node => node.isStream && !node.isSink)
    readonly property var outputDevices: audioNodes.filter(node => !node.isStream && node.isSink)
    readonly property var inputDevices: audioNodes.filter(node => !node.isStream && !node.isSink)
    readonly property bool available: sink !== null && sink.audio !== null
    readonly property bool sourceAvailable: source !== null && source.audio !== null
    readonly property bool muted: !available || sink.audio.muted
    readonly property bool sourceMuted: !sourceAvailable || source.audio.muted
    readonly property int volume: available ? Math.round(sink.audio.volume * 100) : 0
    readonly property int sourceVolume: sourceAvailable
        ? Math.round(source.audio.volume * 100) : 0
    readonly property string icon: muted
        ? ""
        : (volume < 34 ? "" : (volume < 67 ? "" : ""))
    readonly property string sourceIcon: sourceMuted ? "󰍭" : ""

    property PwObjectTracker tracker: PwObjectTracker {
        objects: root.audioNodes
    }

    function displayName(node): string {
        if (!node)
            return "";
        const properties = node.ready ? (node.properties || {}) : {};
        return properties["application.name"] || node.nickname
            || node.description || node.name || "Audio";
    }

    function mediaName(node): string {
        if (!node)
            return "";
        const properties = node.ready ? (node.properties || {}) : {};
        return properties["media.name"] || properties["media.title"] || "";
    }

    function setNodeVolume(node, value: real): void {
        if (!node || !node.audio)
            return;
        const level = Math.max(0, Math.min(1, value));
        node.audio.volume = level;
        if (node.audio.muted && level > 0)
            node.audio.muted = false;
    }

    function toggleNodeMute(node): void {
        if (node && node.audio)
            node.audio.muted = !node.audio.muted;
    }

    function setDefaultOutput(node): void {
        if (node && !node.isStream && node.isSink)
            Pipewire.preferredDefaultAudioSink = node;
    }

    function setDefaultInput(node): void {
        if (node && !node.isStream && !node.isSink)
            Pipewire.preferredDefaultAudioSource = node;
    }

    function toggleMute(): void {
        toggleNodeMute(sink);
    }

    function toggleSourceMute(): void {
        toggleNodeMute(source);
    }

    function setVolume(value: real): void {
        setNodeVolume(sink, value);
    }

    function setSourceVolume(value: real): void {
        setNodeVolume(source, value);
    }
}
