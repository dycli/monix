pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland

Row {
    id: root

    required property string screenName

    spacing: 2

    readonly property int activeWorkspaceId: {
        const monitors = Hyprland.monitors?.values || [];
        const monitor = monitors.find(candidate => candidate.name === screenName);
        return monitor?.activeWorkspace?.id || Hyprland.focusedWorkspace?.id || 1;
    }

    readonly property var workspaceIds: {
        const ids = [];
        const workspaces = Hyprland.workspaces?.values || [];

        for (const workspace of workspaces) {
            if (workspace.id > 0 && !ids.includes(workspace.id))
                ids.push(workspace.id);
        }

        if (root.activeWorkspaceId > 0 && !ids.includes(root.activeWorkspaceId))
            ids.push(root.activeWorkspaceId);

        return ids.sort((left, right) => left - right);
    }

    Repeater {
        model: root.workspaceIds

        delegate: Rectangle {
            id: workspace

            required property int modelData

            readonly property int workspaceId: modelData
            readonly property bool active: workspaceId === root.activeWorkspaceId

            width: 24
            height: 24
            radius: 2
            color: active ? "#eef0f4" : mouse.containsMouse ? "#272a31" : "transparent"

            Text {
                anchors.centerIn: parent
                color: workspace.active ? "#111318" : "#eef0f4"
                font {
                    family: Style.fontFamily
                    pixelSize: 11
                    weight: Style.fontWeight
                }
                renderType: Text.NativeRendering
                text: workspace.workspaceId
            }

            MouseArea {
                id: mouse

                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = " + workspace.workspaceId + " })")
            }
        }
    }
}
