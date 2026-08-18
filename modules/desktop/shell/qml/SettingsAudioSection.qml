pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    spacing: 8

    function nodeLabel(node): string {
        const application = AudioState.displayName(node);
        const media = AudioState.mediaName(node);
        return media.length > 0 ? application + " — " + media : application;
    }

    function volumeIcon(node): string {
        if (!node || !node.audio || node.audio.muted)
            return "";
        const volume = node.audio.volume;
        return volume < 0.34 ? "" : (volume < 0.67 ? "" : "");
    }

    Text {
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelTitleFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Sound"
    }

    SettingsSlider {
        width: parent.width
        available: AudioState.available
        icon: AudioState.icon
        label: AudioState.available ? AudioState.displayName(AudioState.sink) : "No output"
        value: AudioState.volume / 100
        onIconActivated: AudioState.toggleMute()
        onMoved: value => AudioState.setVolume(value)
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Output device"
        visible: AudioState.outputDevices.length > 0
    }

    Repeater {
        model: AudioState.outputDevices

        delegate: SettingsChoiceButton {
            required property var modelData

            width: root.width
            active: AudioState.sink && modelData.id === AudioState.sink.id
            icon: "󰓃"
            label: AudioState.displayName(modelData)
            detail: active ? "Selected" : ""
            onActivated: AudioState.setDefaultOutput(modelData)
        }
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Applications"
        visible: AudioState.outputStreams.length > 0
    }

    Repeater {
        model: AudioState.outputStreams

        delegate: SettingsSlider {
            required property var modelData

            width: root.width
            available: modelData && modelData.audio
            icon: root.volumeIcon(modelData)
            label: root.nodeLabel(modelData)
            value: modelData && modelData.audio ? modelData.audio.volume : 0
            onIconActivated: AudioState.toggleNodeMute(modelData)
            onMoved: value => AudioState.setNodeVolume(modelData, value)
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Style.panelBorderColor
    }

    SettingsSlider {
        width: parent.width
        available: AudioState.sourceAvailable
        icon: AudioState.sourceIcon
        label: AudioState.sourceAvailable
            ? AudioState.displayName(AudioState.source) : "No microphone"
        value: AudioState.sourceVolume / 100
        onIconActivated: AudioState.toggleSourceMute()
        onMoved: value => AudioState.setSourceVolume(value)
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Input device"
        visible: AudioState.inputDevices.length > 0
    }

    Repeater {
        model: AudioState.inputDevices

        delegate: SettingsChoiceButton {
            required property var modelData

            width: root.width
            active: AudioState.source && modelData.id === AudioState.source.id
            icon: ""
            label: AudioState.displayName(modelData)
            detail: active ? "Selected" : ""
            onActivated: AudioState.setDefaultInput(modelData)
        }
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Microphone applications"
        visible: AudioState.inputStreams.length > 0
    }

    Repeater {
        model: AudioState.inputStreams

        delegate: SettingsSlider {
            required property var modelData

            width: root.width
            available: modelData && modelData.audio
            icon: modelData && modelData.audio && modelData.audio.muted ? "󰍭" : ""
            label: root.nodeLabel(modelData)
            value: modelData && modelData.audio ? modelData.audio.volume : 0
            onIconActivated: AudioState.toggleNodeMute(modelData)
            onMoved: value => AudioState.setNodeVolume(modelData, value)
        }
    }
}
