pragma Singleton

import QtQuick
import Quickshell.Services.Mpris

QtObject {
    id: root

    readonly property var players: Mpris.players.values
    readonly property var controllablePlayers: players.filter(player => player.canControl)
    readonly property var playingPlayer: controllablePlayers.find(player => player.isPlaying) || null

    property var player: null

    readonly property bool available: player !== null && player.canControl
    readonly property string title: player?.trackTitle || player?.identity || "Media"
    readonly property string artist: player?.trackArtist || ""

    function selectPlayer(): void {
        if (playingPlayer) {
            player = playingPlayer;
        } else if (!player || !controllablePlayers.includes(player)) {
            player = controllablePlayers.length > 0 ? controllablePlayers[0] : null;
        }
    }

    onPlayersChanged: selectPlayer()
    onControllablePlayersChanged: selectPlayer()
    onPlayingPlayerChanged: selectPlayer()
    Component.onCompleted: selectPlayer()
}
