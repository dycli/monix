pragma ComponentBehavior: Bound

import QtQuick

Row {
    id: root

    property var passwordNetwork: null

    height: 24
    spacing: Style.rightSectionGap

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

    Repeater {
        model: root.passwordNetwork === null && NetworkState.wifiEnabled
            ? NetworkState.visibleNetworks.filter(network => !network.connected) : []

        delegate: BarModeButton {
            required property var modelData

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
        text: NetworkState.wifiDevice === null
            ? "No Wi-Fi adapter"
            : (NetworkState.wifiEnabled ? "No other networks" : "Wi-Fi Off")
        visible: root.passwordNetwork === null
            && (NetworkState.wifiDevice === null || !NetworkState.wifiEnabled
                || NetworkState.visibleNetworks.filter(network => !network.connected).length === 0)
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
}
