pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    property int percentage: 0
    property bool charging: false
    property bool full: false
    property color color: Style.foregroundColor
    property real scaleFactor: 1

    implicitWidth: Math.round(21 * scaleFactor)
    implicitHeight: Math.round(12 * scaleFactor)

    Item {
        id: body

        width: Math.round(20 * root.scaleFactor)
        height: Math.round(10 * root.scaleFactor)
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter

        Canvas {
            id: charge

            readonly property real fillWidth: width * root.percentage / 100
            readonly property color fillColor: root.color
            readonly property real cornerRadius: 2.5 * root.scaleFactor

            anchors.fill: parent

            onFillWidthChanged: requestPaint()
            onFillColorChanged: requestPaint()
            onCornerRadiusChanged: requestPaint()
            onPaint: {
                const context = getContext("2d");
                const radius = Math.min(cornerRadius, width / 2, height / 2);

                context.reset();
                context.beginPath();
                context.moveTo(radius, 0);
                context.lineTo(width - radius, 0);
                context.quadraticCurveTo(width, 0, width, radius);
                context.lineTo(width, height - radius);
                context.quadraticCurveTo(width, height, width - radius, height);
                context.lineTo(radius, height);
                context.quadraticCurveTo(0, height, 0, height - radius);
                context.lineTo(0, radius);
                context.quadraticCurveTo(0, 0, radius, 0);
                context.closePath();

                context.fillStyle = Qt.rgba(fillColor.r, fillColor.g, fillColor.b, 0.3);
                context.fill();
                context.clip();
                context.fillStyle = fillColor;
                context.fillRect(0, 0, fillWidth, height);
            }
        }

        Text {
            anchors.fill: parent
            color: Style.panelColor
            font {
                family: Style.fontFamily
                pixelSize: Math.max(2, Math.round(8 * root.scaleFactor / 2) * 2)
                weight: 500
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering
            text: root.charging ? "" : "✓"
            visible: root.charging || root.full
        }
    }

    Rectangle {
        width: Math.max(1, Math.round(root.scaleFactor))
        height: Math.round(4 * root.scaleFactor)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        radius: 0.5 * root.scaleFactor
        color: root.color
    }
}
