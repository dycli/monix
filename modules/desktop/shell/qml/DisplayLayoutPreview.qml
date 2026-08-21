pragma ComponentBehavior: Bound

import QtQuick

Rectangle {
    id: root

    readonly property var internalSize: DisplayState.logicalSize(DisplayState.internalOutput)
    readonly property var externalSize: DisplayState.logicalSize(DisplayState.externalOutput)
    readonly property real maximumLogicalHeight: Math.max(internalSize.height, externalSize.height)
    readonly property real previewScale: 88 / Math.max(1, maximumLogicalHeight)
    readonly property real internalWidth: Math.max(72, internalSize.width * previewScale)
    readonly property real internalHeight: Math.max(44, internalSize.height * previewScale)
    readonly property real externalWidth: Math.max(72, externalSize.width * previewScale)
    readonly property real externalHeight: Math.max(44, externalSize.height * previewScale)
    readonly property real contentWidth: internalWidth + externalWidth + 6
    readonly property real topOffset: DisplayState.alignment === "top" ? 0
        : (DisplayState.alignment === "center" ? 0.5 : 1)

    implicitHeight: 118
    radius: 8
    color: Qt.rgba(1, 1, 1, 0.035)
    border {
        width: 1
        color: Style.panelBorderColor
    }

    Item {
        anchors.centerIn: parent
        width: root.contentWidth
        height: Math.max(root.internalHeight, root.externalHeight)

        Rectangle {
            id: internalDisplay

            x: DisplayState.side === "left" ? root.externalWidth + 6 : 0
            y: (parent.height - height) * root.topOffset
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
                elide: Text.ElideRight
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
            x: DisplayState.side === "left" ? 0 : root.internalWidth + 6
            y: (parent.height - height) * root.topOffset
            width: root.externalWidth
            height: root.externalHeight
            radius: 5
            color: Qt.rgba(1, 1, 1, 0.07)
            border {
                width: 1
                color: Style.panelMutedColor
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
        }
    }
}
