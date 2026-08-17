pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

PopupWindow {
    id: root

    required property Item anchorItem
    required property string screenName

    property date shownMonth: new Date(new Date().getFullYear(), new Date().getMonth(), 1)
    property date selectedDate: new Date()

    color: "transparent"
    implicitWidth: 410
    implicitHeight: 650
    grabFocus: true
    visible: ClockPanelService.isOpen(screenName)

    onVisibleChanged: {
        if (!visible && ClockPanelService.isOpen(screenName))
            ClockPanelService.close();
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: ClockPanelService.close()
    }

    anchor {
        id: popupAnchor

        window: root.anchorItem ? root.anchorItem.QsWindow.window : null
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
            if (!root.anchorItem || !window)
                return;
            const point = window.contentItem.mapFromItem(root.anchorItem,
                root.anchorItem.width - root.implicitWidth, root.anchorItem.height + 6);
            popupAnchor.rect.x = Math.max(8, Math.min(point.x, window.width - root.implicitWidth - 8));
            popupAnchor.rect.y = Math.round(point.y);
        }
    }

    function monthDays() {
        const first = new Date(shownMonth.getFullYear(), shownMonth.getMonth(), 1);
        const offset = (first.getDay() + 6) % 7;
        const start = new Date(first);
        start.setDate(first.getDate() - offset);
        const days = [];
        for (let index = 0; index < 42; index += 1) {
            const date = new Date(start);
            date.setDate(start.getDate() + index);
            days.push(date);
        }
        return days;
    }

    function sameDay(left, right): bool {
        return left.getFullYear() === right.getFullYear()
            && left.getMonth() === right.getMonth()
            && left.getDate() === right.getDate();
    }

    function moveMonth(delta: int): void {
        shownMonth = new Date(shownMonth.getFullYear(), shownMonth.getMonth() + delta, 1);
    }

    Rectangle {
        anchors.fill: parent
        color: Style.panelColor
        border.color: Style.panelBorderColor
        border.width: 1
        radius: 12

        Column {
            anchors {
                fill: parent
                margins: 18
            }
            spacing: 12

            Column {
                width: parent.width
                height: 322
                spacing: 12

                Item {
                    x: Math.round((parent.width - width) / 2)
                    width: 280
                    height: 28

                    Text {
                        anchors {
                            left: parent.left
                            verticalCenter: parent.verticalCenter
                        }
                        color: Style.foregroundColor
                        font {
                            family: Style.fontFamily
                            pixelSize: Style.panelTitleFontSize
                            weight: Style.fontWeight
                        }
                        text: Qt.formatDate(root.shownMonth, "MMMM yyyy")
                    }

                    Row {
                        anchors {
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                        }

                        Repeater {
                            model: [{ "icon": "󰁍", "delta": -1 }, { "icon": "󰁔", "delta": 1 }]

                            delegate: BarModeButton {
                                required property var modelData
                                icon: modelData.icon
                                onActivated: root.moveMonth(modelData.delta)
                            }
                        }
                    }
                }

                Grid {
                    x: Math.round((parent.width - width) / 2)
                    width: 280
                    columns: 7

                    Repeater {
                        model: ["M", "T", "W", "T", "F", "S", "S"]

                        delegate: Text {
                            required property string modelData
                            width: 40
                            height: 24
                            color: Style.panelMutedColor
                            font {
                                family: Style.fontFamily
                                pixelSize: Style.panelFontSize
                                weight: Style.fontWeight
                            }
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: modelData
                        }
                    }

                    Repeater {
                        model: root.monthDays()

                        delegate: Item {
                            id: dayCell

                            required property date modelData
                            readonly property bool currentMonth: modelData.getMonth() === root.shownMonth.getMonth()
                            readonly property bool today: root.sameDay(modelData, new Date())
                            readonly property bool selected: root.sameDay(modelData, root.selectedDate)

                            width: 40
                            height: 43

                            Rectangle {
                                anchors.centerIn: parent
                                width: 28
                                height: 28
                                radius: 14
                                color: dayCell.selected ? Style.foregroundColor : "transparent"
                            }

                            Text {
                                anchors.centerIn: parent
                                color: dayCell.selected
                                    ? Style.panelColor
                                    : (dayCell.currentMonth ? Style.foregroundColor : Style.panelMutedColor)
                                opacity: dayCell.currentMonth || dayCell.selected ? 1 : 0.55
                                font {
                                    family: Style.fontFamily
                                    pixelSize: Style.panelFontSize
                                    weight: dayCell.today ? 700 : Style.fontWeight
                                }
                                text: dayCell.modelData.getDate()
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectedDate = dayCell.modelData
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Style.panelBorderColor
            }

            Column {
                width: parent.width
                height: parent.height - 347
                spacing: 10

                Item {
                    width: parent.width
                    height: 28

                    Text {
                        anchors {
                            left: parent.left
                            verticalCenter: parent.verticalCenter
                        }
                        color: Style.foregroundColor
                        font {
                            family: Style.fontFamily
                            pixelSize: Style.panelTitleFontSize
                            weight: Style.fontWeight
                        }
                        text: "Notifications"
                    }

                    Text {
                        anchors {
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                        }
                        color: Style.panelMutedColor
                        font {
                            family: Style.fontFamily
                            pixelSize: Style.panelFontSize
                            weight: Style.fontWeight
                        }
                        text: "Clear"
                        visible: NotificationState.historyModel.count > 0

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: NotificationState.clear()
                        }
                    }
                }

                ListView {
                    width: parent.width
                    height: parent.height - 38
                    clip: true
                    spacing: 4
                    model: NotificationState.historyModel

                    delegate: Item {
                        id: notificationRow

                        required property int index
                        required property string app
                        required property string summary
                        required property string body

                        width: ListView.view.width
                        height: body.length > 0 ? 72 : 52

                        Column {
                            anchors {
                                left: parent.left
                                right: closeButton.left
                                rightMargin: 8
                                verticalCenter: parent.verticalCenter
                            }
                            spacing: 2

                            Text {
                                width: parent.width
                                color: Style.panelMutedColor
                                elide: Text.ElideRight
                                font {
                                    family: Style.fontFamily
                                    pixelSize: 10
                                    weight: Style.fontWeight
                                }
                                text: notificationRow.app
                            }

                            Text {
                                width: parent.width
                                color: Style.foregroundColor
                                elide: Text.ElideRight
                                font {
                                    family: Style.fontFamily
                                    pixelSize: Style.panelFontSize
                                    weight: Style.fontWeight
                                }
                                text: notificationRow.summary
                            }

                            Text {
                                width: parent.width
                                color: Style.panelMutedColor
                                elide: Text.ElideRight
                                font {
                                    family: Style.fontFamily
                                    pixelSize: 10
                                    weight: Style.fontWeight
                                }
                                text: notificationRow.body
                                visible: body.length > 0
                            }
                        }

                        Text {
                            id: closeButton

                            anchors {
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                            }
                            color: Style.panelMutedColor
                            font {
                                family: Style.fontFamily
                                pixelSize: 14
                                weight: Style.fontWeight
                            }
                            text: "×"

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -8
                                cursorShape: Qt.PointingHandCursor
                                onClicked: NotificationState.dismiss(notificationRow.index)
                            }
                        }

                        MouseArea {
                            anchors {
                                left: parent.left
                                right: closeButton.left
                                top: parent.top
                                bottom: parent.bottom
                            }
                            cursorShape: Qt.PointingHandCursor
                            onClicked: NotificationState.invokeDefault(notificationRow.index)
                        }

                        Rectangle {
                            anchors {
                                left: parent.left
                                right: parent.right
                                bottom: parent.bottom
                            }
                            height: 1
                            color: Style.panelBorderColor
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        color: Style.panelMutedColor
                        font {
                            family: Style.fontFamily
                            pixelSize: Style.panelFontSize
                            weight: Style.fontWeight
                        }
                        text: "No notifications"
                        visible: NotificationState.historyModel.count === 0
                    }
                }
            }
        }
    }
}
