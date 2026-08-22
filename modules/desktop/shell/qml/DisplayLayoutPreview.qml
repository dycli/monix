pragma ComponentBehavior: Bound

import QtQuick

Rectangle {
    id: root

    readonly property var internalSize: DisplayState.logicalSize(DisplayState.internalOutput)
    readonly property var externalSize: DisplayState.logicalSize(DisplayState.externalOutput)
    readonly property real previewScale: Math.min(
        Math.max(0.01, (width - 48) / Math.max(1,
            internalSize.width + externalSize.width)),
        Math.max(0.01, (height - 48) / Math.max(1,
            internalSize.height + externalSize.height)))
    readonly property real internalWidth: Math.max(48, internalSize.width * previewScale)
    readonly property real internalHeight: Math.max(36, internalSize.height * previewScale)
    readonly property real externalWidth: Math.max(48, externalSize.width * previewScale)
    readonly property real externalHeight: Math.max(36, externalSize.height * previewScale)
    readonly property real renderedExternalX: DisplayState.externalPositionX * previewScale
    readonly property real renderedExternalY: DisplayState.externalPositionY * previewScale
    readonly property real layoutMinimumX: Math.min(0, renderedExternalX)
    readonly property real layoutMinimumY: Math.min(0, renderedExternalY)
    readonly property real layoutMaximumX: Math.max(internalWidth,
        renderedExternalX + externalWidth)
    readonly property real layoutMaximumY: Math.max(internalHeight,
        renderedExternalY + externalHeight)
    readonly property real layoutWidth: layoutMaximumX - layoutMinimumX
    readonly property real layoutHeight: layoutMaximumY - layoutMinimumY
    readonly property real layoutOriginX: (width - layoutWidth) / 2 - layoutMinimumX
    readonly property real layoutOriginY: (height - layoutHeight) / 2 - layoutMinimumY

    implicitHeight: 180
    radius: 8
    color: Qt.rgba(1, 1, 1, 0.035)
    border {
        width: 1
        color: Style.panelBorderColor
    }

    function clamp(value: real, minimum: real, maximum: real): real {
        return Math.max(minimum, Math.min(maximum, value));
    }

    function commitPosition(displayX: real, displayY: real): void {
        let relativeX = (displayX - internalDisplay.x) / previewScale;
        let relativeY = (displayY - internalDisplay.y) / previewScale;
        const distances = [
            Math.abs(relativeX - internalSize.width),
            Math.abs(relativeX + externalSize.width),
            Math.abs(relativeY - internalSize.height),
            Math.abs(relativeY + externalSize.height)
        ];
        let edge = 0;
        for (let index = 1; index < distances.length; index++) {
            if (distances[index] < distances[edge])
                edge = index;
        }

        const overlap = Math.min(160, internalSize.height / 3,
            externalSize.height / 3);
        const snapDistance = 12 / previewScale;
        if (edge === 0 || edge === 1) {
            relativeX = edge === 0 ? internalSize.width : -externalSize.width;
            relativeY = clamp(relativeY, -externalSize.height + overlap,
                internalSize.height - overlap);
            const bottomAligned = internalSize.height - externalSize.height;
            if (Math.abs(relativeY) <= snapDistance)
                relativeY = 0;
            else if (Math.abs(relativeY - bottomAligned) <= snapDistance)
                relativeY = bottomAligned;
        } else {
            relativeY = edge === 2 ? internalSize.height : -externalSize.height;
            relativeX = clamp(relativeX, -externalSize.width + overlap,
                internalSize.width - overlap);
            const rightAligned = internalSize.width - externalSize.width;
            if (Math.abs(relativeX) <= snapDistance)
                relativeX = 0;
            else if (Math.abs(relativeX - rightAligned) <= snapDistance)
                relativeX = rightAligned;
        }
        DisplayState.setPosition(relativeX, relativeY);
    }

    Rectangle {
        id: internalDisplay

        x: Math.round(root.layoutOriginX)
        y: Math.round(root.layoutOriginY)
        width: root.internalWidth
        height: root.internalHeight
        radius: 5
        color: Qt.rgba(1, 1, 1, 0.11)
        border {
            width: 1
            color: Style.foregroundColor
        }

        Text {
            anchors.centerIn: parent
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.smallFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: "Laptop"
        }
    }

    Rectangle {
        id: externalDisplay

        property bool dragging: false
        property real dragX: 0
        property real dragY: 0
        property real startX: 0
        property real startY: 0

        x: dragging ? dragX : Math.round(root.layoutOriginX + root.renderedExternalX)
        y: dragging ? dragY : Math.round(root.layoutOriginY + root.renderedExternalY)
        width: root.externalWidth
        height: root.externalHeight
        radius: 5
        color: Qt.rgba(1, 1, 1, dragHandler.active ? 0.15 : 0.07)
        border {
            width: dragHandler.active ? 2 : 1
            color: Style.foregroundColor
        }

        Text {
            anchors {
                left: parent.left
                right: parent.right
                margins: 6
                verticalCenter: parent.verticalCenter
            }
            color: Style.foregroundColor
            elide: Text.ElideRight
            font {
                family: Style.fontFamily
                pixelSize: Style.smallFontSize
                weight: Style.fontWeight
            }
            horizontalAlignment: Text.AlignHCenter
            renderType: Text.NativeRendering
            text: DisplayState.externalLabel
        }

        HoverHandler {
            cursorShape: Qt.OpenHandCursor
        }

        DragHandler {
            id: dragHandler

            target: null
            enabled: !DisplayState.busy

            onActiveChanged: {
                if (active) {
                    externalDisplay.startX = externalDisplay.x;
                    externalDisplay.startY = externalDisplay.y;
                    externalDisplay.dragX = externalDisplay.x;
                    externalDisplay.dragY = externalDisplay.y;
                    externalDisplay.dragging = true;
                } else if (externalDisplay.dragging) {
                    root.commitPosition(externalDisplay.dragX, externalDisplay.dragY);
                    externalDisplay.dragging = false;
                }
            }

            onTranslationChanged: {
                if (!active)
                    return;
                externalDisplay.dragX = root.clamp(
                    externalDisplay.startX + translation.x,
                    6, root.width - externalDisplay.width - 6);
                externalDisplay.dragY = root.clamp(
                    externalDisplay.startY + translation.y,
                    6, root.height - externalDisplay.height - 6);
            }
        }
    }
}
