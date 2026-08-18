pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland

Row {
    id: root

    required property string screenName
    property real scaleFactor: 1

    spacing: 0

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

            width: Math.round(22 * root.scaleFactor)
            height: Math.round(24 * root.scaleFactor)
            color: "transparent"

            Canvas {
                id: workspaceShape

                width: Math.round(14 * root.scaleFactor)
                height: width
                anchors.centerIn: parent
                antialiasing: true

                onPaint: {
                    const context = getContext("2d");
                    const inset = 1;
                    const center = width / 2;
                    const radius = center - inset;

                    context.reset();
                    context.fillStyle = workspace.active
                        ? Style.foregroundColor : Style.inactiveWorkspaceColor;
                    context.beginPath();

                    if (workspace.workspaceId === 1) {
                        context.arc(center, center, radius, 0, Math.PI * 2);
                    } else if (workspace.workspaceId === 2) {
                        const thickness = 3;
                        context.moveTo(inset, height - inset);
                        context.lineTo(inset + thickness, height - inset);
                        context.lineTo(width - inset, inset);
                        context.lineTo(width - inset - thickness, inset);
                        context.closePath();
                    } else {
                        const sides = workspace.workspaceId;
                        const points = [];
                        let minimumX = width;
                        let maximumX = 0;
                        let minimumY = height;
                        let maximumY = 0;

                        for (let side = 0; side < sides; side++) {
                            const angle = -Math.PI / 2 + side * Math.PI * 2 / sides;
                            const x = center + radius * Math.cos(angle);
                            const y = center + radius * Math.sin(angle);
                            points.push({ x, y });
                            minimumX = Math.min(minimumX, x);
                            maximumX = Math.max(maximumX, x);
                            minimumY = Math.min(minimumY, y);
                            maximumY = Math.max(maximumY, y);
                        }

                        const boundsCenterX = (minimumX + maximumX) / 2;
                        const boundsCenterY = (minimumY + maximumY) / 2;
                        const shapeScale = (height - inset * 2) / (maximumY - minimumY);
                        for (let side = 0; side < points.length; side++) {
                            const x = center + (points[side].x - boundsCenterX) * shapeScale;
                            const y = center + (points[side].y - boundsCenterY) * shapeScale;
                            if (side === 0)
                                context.moveTo(x, y);
                            else
                                context.lineTo(x, y);
                        }
                        context.closePath();
                    }

                    context.fill();
                }
            }

            onActiveChanged: workspaceShape.requestPaint()

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = " + workspace.workspaceId + " })")
            }
        }
    }
}
