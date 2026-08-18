pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland

QtObject {
    id: root

    readonly property string focusedScreenName: Hyprland.focusedMonitor
        ? Hyprland.focusedMonitor.name
        : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "")

    function flash(mode: string): void {
        if (focusedScreenName.length > 0)
            BarModeService.flash(mode, focusedScreenName);
    }

    function volumeUp(): void {
        AudioState.setVolume((AudioState.volume + 5) / 100);
        flash("volume");
    }

    function volumeDown(): void {
        AudioState.setVolume((AudioState.volume - 5) / 100);
        flash("volume");
    }

    function toggleMute(): void {
        AudioState.toggleMute();
        flash("volume");
    }

    function toggleMicMute(): void {
        AudioState.toggleSourceMute();
        flash("microphone");
    }

    function brightnessUp(): void {
        BrightnessState.setLevel(BrightnessState.level + 0.01);
        flash("brightness");
    }

    function brightnessDown(): void {
        BrightnessState.setLevel(BrightnessState.level - 0.01);
        flash("brightness");
    }

    function showPowerProfile(): void {
        flash("profile");
    }

}
