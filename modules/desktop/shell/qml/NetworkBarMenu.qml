pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    signal backRequested
    signal closeRequested

    property var passwordNetwork: null

    height: 24
    spacing: 4

    function chooseNetwork(network): void {
        if (NetworkState.activate(network))
            return;
        passwordNetwork = network;
        BarModeService.wantsKeyboard = true;
        Qt.callLater(() => passwordInput.forceActiveFocus());
    }

    function cancelPassword(): void {
        passwordNetwork = null;
        passwordInput.text = "";
        BarModeService.wantsKeyboard = false;
    }

    function submitPassword(): void {
        if (!passwordNetwork || passwordInput.text.length === 0)
            return;
        NetworkState.connectWithPassword(passwordNetwork, passwordInput.text);
        cancelPassword();
    }

    onVisibleChanged: {
        if (!visible)
            cancelPassword();
    }

    Binding {
        target: NetworkState.wifiDevice
        property: "scannerEnabled"
        value: true
        when: root.visible && NetworkState.wifiDevice !== null
        restoreMode: Binding.RestoreBindingOrValue
    }

    BarModeButton {
        icon: "󰁍"
        onActivated: root.backRequested()
    }

    BarModeButton {
        active: NetworkState.wiredConnected
        enabled: NetworkState.wiredNetwork !== null
        icon: "󰈀"
        label: NetworkState.wiredConnected ? "Ethernet Connected" : "Ethernet Disconnected"
        visible: root.passwordNetwork === null && NetworkState.wiredDevice !== null
        onActivated: NetworkState.activateWired()
    }

    BarModeButton {
        active: NetworkState.wifiEnabled
        enabled: NetworkState.available && NetworkState.wifiHardwareEnabled
        icon: NetworkState.wifiEnabled ? "󰖩" : "󰖪"
        label: NetworkState.wifiEnabled ? "Wi-Fi On" : "Wi-Fi Off"
        visible: root.passwordNetwork === null && NetworkState.wifiDevice !== null
        onActivated: NetworkState.toggleWifi()
    }

    Repeater {
        model: root.passwordNetwork === null && NetworkState.wifiEnabled
            ? NetworkState.visibleNetworks : []

        delegate: BarModeButton {
            required property var modelData

            active: modelData.connected
            icon: "󰖩"
            label: modelData.name + " " + Math.round(modelData.signalStrength * 100) + "%"
            maximumWidth: 150
            onActivated: root.chooseNetwork(modelData)
        }
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: "No networks"
        visible: root.passwordNetwork === null && NetworkState.wifiDevice !== null
            && NetworkState.wifiEnabled && NetworkState.visibleNetworks.length === 0
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        color: Style.foregroundColor
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        renderType: Text.NativeRendering
        text: root.passwordNetwork ? root.passwordNetwork.name : ""
        visible: root.passwordNetwork !== null
    }

    TextInput {
        id: passwordInput

        width: 150
        height: parent.height
        verticalAlignment: TextInput.AlignVCenter
        color: Style.foregroundColor
        selectionColor: Style.foregroundColor
        selectedTextColor: "#000000"
        echoMode: TextInput.Password
        font {
            family: Style.fontFamily
            pixelSize: Style.textFontSize
            weight: Style.fontWeight
        }
        visible: root.passwordNetwork !== null
        onAccepted: root.submitPassword()

        Text {
            anchors.verticalCenter: parent.verticalCenter
            color: Style.inactiveWorkspaceColor
            font: parent.font
            renderType: Text.NativeRendering
            text: "Password"
            visible: parent.text.length === 0 && !parent.activeFocus
        }
    }

    BarModeButton {
        label: "Connect"
        enabled: passwordInput.text.length > 0
        visible: root.passwordNetwork !== null
        onActivated: root.submitPassword()
    }

    BarModeButton {
        label: "Cancel"
        visible: root.passwordNetwork !== null
        onActivated: root.cancelPassword()
    }

    SettingsButton {
        anchors.verticalCenter: parent.verticalCenter
        onMenuToggleRequested: root.closeRequested()
    }
}
