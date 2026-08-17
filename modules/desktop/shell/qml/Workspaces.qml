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
        const ids = [1, 2, 3, 4, 5];
        const workspaces = Hyprland.workspaces?.values || [];

        for (const workspace of workspaces) {
            if (workspace.id > 0 && !ids.includes(workspace.id))
                ids.push(workspace.id);
        }

        return ids.sort((left, right) => left - right);
    }

    readonly property var occupiedWorkspaceIds: {
        const ids = [];
        const toplevels = Hyprland.toplevels?.values || [];

        for (const toplevel of toplevels) {
            const id = toplevel.workspace?.id;
            if (id > 0 && !ids.includes(id))
                ids.push(id);
        }

        return ids;
    }

    Repeater {
        model: root.workspaceIds

        delegate: Rectangle {
            id: workspace

            required property int modelData

            readonly property int workspaceId: modelData
            readonly property bool active: workspaceId === root.activeWorkspaceId
            readonly property bool occupied: root.occupiedWorkspaceIds.includes(workspaceId)

            width: 24
            height: 24
            radius: 2
            color: active ? "#eef0f4" : mouse.containsMouse ? "#272a31" : "transparent"

            Text {
                anchors.centerIn: parent
                color: workspace.active ? "#111318" : workspace.occupied ? "#eef0f4" : "#737985"
                font {
                    family: "Noto Sans"
                    pixelSize: 11
                    weight: workspace.active ? Font.DemiBold : Font.Normal
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
