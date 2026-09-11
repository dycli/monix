pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    signal dismissed

    property bool armed: false
    property bool tracking: false
    property real pointerOriginX: 0
    property real pointerOriginY: 0

    function reset(): void {
        armed = false;
        tracking = false;
    }

    visible: !armed
    z: 1

    MouseArea {
        id: pointer

        anchors.fill: parent
        hoverEnabled: true
        onEntered: {
            root.pointerOriginX = pointer.mouseX;
            root.pointerOriginY = pointer.mouseY;
            root.tracking = true;
        }
        onExited: root.tracking = false
        onPositionChanged: event => {
            if (root.tracking
                    && (Math.abs(event.x - root.pointerOriginX) >= 4
                        || Math.abs(event.y - root.pointerOriginY) >= 4))
                root.armed = true;
        }
        onClicked: root.dismissed()
    }
}
