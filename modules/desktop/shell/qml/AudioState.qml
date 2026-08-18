pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Pipewire

QtObject {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool available: sink !== null && sink.audio !== null
    readonly property bool sourceAvailable: source !== null && source.audio !== null
    readonly property bool muted: !available || sink.audio.muted
    readonly property bool sourceMuted: !sourceAvailable || source.audio.muted
    readonly property int volume: available ? Math.round(sink.audio.volume * 100) : 0
    readonly property string icon: muted
        ? ""
        : (volume < 34 ? "" : (volume < 67 ? "" : ""))
    readonly property string label: available && !muted ? volume + "%" : ""
    readonly property string sourceIcon: sourceMuted ? "󰍭" : ""

    property PwObjectTracker tracker: PwObjectTracker {
        objects: Pipewire.nodes.values.filter(node => node.audio && !node.isStream)
    }

    function mute(): void {
        if (available)
            sink.audio.muted = true;
    }

    function toggleMute(): void {
        if (available)
            sink.audio.muted = !sink.audio.muted;
    }

    function toggleSourceMute(): void {
        if (sourceAvailable)
            source.audio.muted = !source.audio.muted;
    }

    function setVolume(value: real): void {
        if (!available)
            return;
        sink.audio.volume = Math.max(0, Math.min(1, value));
        if (sink.audio.muted && value > 0)
            sink.audio.muted = false;
    }
}
