pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    required property string screenName

    readonly property bool active: BarModeService.activeMode === "launcher"
        && BarModeService.screenName === screenName
    readonly property var results: LauncherService.results(search.text, 20)

    property int selectedIndex: 0

    visible: active

    onActiveChanged: {
        if (active) {
            search.text = "";
            selectedIndex = 0;
            resultsView.contentX = 0;
            focusTimer.restart();
        }
    }

    onResultsChanged: selectedIndex = Math.min(selectedIndex,
        Math.max(0, results.length - 1))
    onSelectedIndexChanged: Qt.callLater(() => resultsView.reveal(selectedIndex))

    function moveSelection(offset: int): void {
        if (results.length === 0)
            return;
        selectedIndex = (selectedIndex + offset + results.length) % results.length;
    }

    function launchSelected(): void {
        if (results.length > 0)
            LauncherService.launch(results[selectedIndex]);
    }

    Timer {
        id: focusTimer
        interval: 0
        onTriggered: search.forceActiveFocus()
    }

    Row {
        anchors.fill: parent
        spacing: 8

        Item {
            id: searchBox

            width: Math.min(160, Math.max(120, root.width * 0.25))
            height: parent.height

            TextInput {
                id: search

                anchors.fill: parent
                color: Style.foregroundColor
                clip: true
                font {
                    family: Style.fontFamily
                    pixelSize: Style.textFontSize
                    weight: Style.fontWeight
                }
                selectionColor: Style.foregroundColor
                selectedTextColor: "#000000"
                verticalAlignment: TextInput.AlignVCenter
                onTextChanged: {
                    root.selectedIndex = 0;
                    resultsView.contentX = 0;
                }

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Right || event.key === Qt.Key_Down
                            || (event.key === Qt.Key_Tab
                                && !(event.modifiers & Qt.ShiftModifier))) {
                        root.moveSelection(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up
                               || (event.key === Qt.Key_Backtab)
                               || (event.key === Qt.Key_Tab
                                   && (event.modifiers & Qt.ShiftModifier))) {
                        root.moveSelection(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.launchSelected();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape) {
                        BarModeService.close();
                        event.accepted = true;
                    }
                }
            }
        }

        Item {
            width: Math.max(0, parent.width - searchBox.width - parent.spacing)
            height: parent.height
            clip: true

            Flickable {
                id: resultsView

                anchors.fill: parent
                contentWidth: resultsRow.implicitWidth
                contentHeight: height
                interactive: false

                function reveal(index: int): void {
                    const item = resultRepeater.itemAt(index);
                    if (!item) {
                        contentX = 0;
                        return;
                    }
                    if (item.x < contentX)
                        contentX = item.x;
                    else if (item.x + item.width > contentX + width)
                        contentX = item.x + item.width - width;
                }

                Row {
                    id: resultsRow

                    height: parent.height
                    spacing: Style.barItemGap

                    Repeater {
                        id: resultRepeater

                        model: root.results

                        delegate: MouseArea {
                            id: result

                            required property int index
                            required property var modelData

                            width: appName.implicitWidth
                            height: parent.height
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onEntered: root.selectedIndex = index
                            onClicked: event => {
                                const mode = event.button === Qt.RightButton
                                    ? "floating" : (event.button === Qt.MiddleButton
                                        ? "workspace" : "normal");
                                LauncherService.launch(modelData, mode);
                            }

                            Text {
                                id: appName

                                anchors.verticalCenter: parent.verticalCenter
                                color: result.index === root.selectedIndex
                                    ? Style.foregroundColor : Style.inactiveWorkspaceColor
                                font {
                                    family: Style.fontFamily
                                    pixelSize: Style.textFontSize
                                    weight: result.index === root.selectedIndex
                                        ? Font.DemiBold : Style.fontWeight
                                }
                                renderType: Text.NativeRendering
                                text: result.modelData.name
                            }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        color: Style.inactiveWorkspaceColor
                        font {
                            family: Style.fontFamily
                            pixelSize: Style.textFontSize
                            weight: Style.fontWeight
                        }
                        renderType: Text.NativeRendering
                        text: "No applications"
                        visible: root.results.length === 0
                    }
                }
            }
        }
    }
}
