pragma ComponentBehavior: Bound

import QtQuick

Column {
    id: root

    required property bool panelVisible

    property var passwordNetwork: null

    spacing: 8

    function chooseNetwork(network): void {
        if (NetworkState.activate(network))
            return;
        passwordNetwork = network;
        passwordInput.text = "";
        Qt.callLater(() => passwordInput.forceActiveFocus());
    }

    function cancelPassword(): void {
        passwordNetwork = null;
        passwordInput.text = "";
    }

    function submitPassword(): void {
        if (!passwordNetwork || passwordInput.text.length === 0)
            return;
        NetworkState.connectWithPassword(passwordNetwork, passwordInput.text);
        cancelPassword();
    }

    onPanelVisibleChanged: {
        if (!panelVisible)
            cancelPassword();
    }

    Binding {
        target: NetworkState.wifiDevice
        property: "scannerEnabled"
        value: true
        when: root.panelVisible && NetworkState.wifiDevice !== null
        restoreMode: Binding.RestoreBindingOrValue
    }

    Text {
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelTitleFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Network"
    }

    SettingsChoiceButton {
        width: parent.width
        active: NetworkState.wifiEnabled
        icon: NetworkState.wifiEnabled ? "󰖩" : "󰖪"
        label: NetworkState.wifiEnabled ? "Wi-Fi" : "Wi-Fi off"
        detail: NetworkState.connectedWifiNetwork
            ? NetworkState.connectedWifiNetwork.name : ""
        visible: NetworkState.wifiDevice !== null
        onActivated: NetworkState.toggleWifi()
    }

    SettingsChoiceButton {
        width: parent.width
        active: NetworkState.wiredConnected
        icon: NetworkState.wiredConnected ? "󰈀" : "󰈂"
        label: "Ethernet"
        detail: NetworkState.wiredConnected ? "Connected" : "Disconnected"
        visible: NetworkState.wiredDevice !== null
        onActivated: NetworkState.connectWired()
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.smallFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "Available networks"
        visible: NetworkState.wifiEnabled && root.passwordNetwork === null
    }

    Repeater {
        model: NetworkState.wifiEnabled && root.passwordNetwork === null
            ? NetworkState.networks.slice(0, 8) : []

        delegate: SettingsChoiceButton {
            required property var modelData

            width: root.width
            active: modelData.connected
            icon: modelData.connected ? "󰖩" : ""
            label: modelData.name
            detail: modelData.connected ? "Connected"
                : Math.round(modelData.signalStrength * 100) + "%"
            onActivated: root.chooseNetwork(modelData)
        }
    }

    Text {
        color: Style.panelMutedColor
        font {
            family: Style.fontFamily
            pixelSize: Style.panelFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: NetworkState.wifiDevice === null
            ? "No Wi-Fi adapter" : (NetworkState.wifiEnabled ? "No networks found" : "")
        visible: root.passwordNetwork === null
            && (NetworkState.wifiDevice === null
                || (NetworkState.wifiEnabled && NetworkState.networks.length === 0))
    }

    Column {
        width: parent.width
        spacing: 8
        visible: root.passwordNetwork !== null

        Text {
            color: Style.foregroundColor
            font {
                family: Style.fontFamily
                pixelSize: Style.panelFontSize
                weight: Style.fontWeight
            }
            renderType: Text.NativeRendering
            text: root.passwordNetwork ? root.passwordNetwork.name : ""
        }

        Item {
            width: parent.width
            height: 34

            TextInput {
                id: passwordInput

                anchors.fill: parent
                color: Style.foregroundColor
                echoMode: TextInput.Password
                font {
                    family: Style.fontFamily
                    pixelSize: Style.panelFontSize
                    weight: Style.fontWeight
                }
                selectionColor: Style.foregroundColor
                selectedTextColor: Style.panelColor
                verticalAlignment: TextInput.AlignVCenter
                onAccepted: root.submitPassword()
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: Style.panelMutedColor
                font: passwordInput.font
                renderType: Text.NativeRendering
                text: "Password"
                visible: passwordInput.text.length === 0
                    && !passwordInput.activeFocus
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

        Row {
            spacing: 8

            SettingsChoiceButton {
                width: 100
                interactive: passwordInput.text.length > 0
                label: "Connect"
                onActivated: root.submitPassword()
            }

            SettingsChoiceButton {
                width: 100
                label: "Cancel"
                onActivated: root.cancelPassword()
            }
        }
    }
}
