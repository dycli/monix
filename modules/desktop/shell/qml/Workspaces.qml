pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland

Row {
    id: root

    required property string screenName

    spacing: 0

    readonly property var workspaceNames: [
        "",
        "One",
        "Two",
        "Three",
        "Four",
        "Five",
        "Six",
        "Seven",
        "Eight",
        "Nine",
        "Ten"
    ]

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

            width: workspaceLabel.implicitWidth + 12
            height: 24
            color: "transparent"

            Text {
                id: workspaceLabel

                anchors.centerIn: parent
                color: workspace.active ? Style.foregroundColor : Style.inactiveWorkspaceColor
                font {
                    family: Style.fontFamily
                    pixelSize: Style.textFontSize
                    weight: workspace.active ? Style.fontWeight : Font.Normal
                }
                renderType: Text.NativeRendering
                text: root.workspaceNames[workspace.workspaceId]
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = " + workspace.workspaceId + " })")
            }
        }
    }
}
