# Hex, local voice dictation. Its window and model live per user, so it is a
# Home Manager module; the key that drives it is in hyprland/keybinds.mod.nix,
# because Hyprland's portal registers global shortcuts without a key.
{
  self,
  inputs,
  lib,
  ...
}:
{
  # Linux only: the flake's package and module build for Linux alone.
  flake.nixosModules.desktop = self.nixosModules.hex;

  flake.homeModules.hex = {
    imports = lib.lists.singleton inputs.hex.homeManagerModules.hex;

    programs.hex = {
      enable = true;
      autostart = true;
      installModel = true;
      settings.shortcut_mode = "toggle";
    };
  };

  # On macOS Hex comes from its own tap, and the settings go in as its Home
  # Manager module applies them on Linux.
  flake.darwinModules.desktop = self.darwinModules.hex-darwin;
  flake.darwinModules.hex-darwin =
    { config, pkgs, ... }:
    let
      inherit (lib.lists) singleton;

      settings = (pkgs.formats.json { }).generate "hex-settings.json" {
        shortcut_mode = "toggle";
        # Caps Lock starts and stops dictation; it is a per-user setting
        # that needs Input Monitoring for the key's light.
        "labs.caps_lock_dictation" = true;
        # The default shortcut is a modifier hammerspoon.mod.nix chords
        # with; F18 is a key the keyboard does not have.
        dictation_hotkey = "f18";
      };
    in
    {
      homebrew.casks = singleton "anomalyco/tap/hex";

      home-manager.users.${config.primaryUser} =
        { config, lib, ... }:
        let
          hex = "${config.home.homeDirectory}/Applications/Hex.app/Contents/MacOS/hex";
        in
        {
          # A running Hex adopts the settings at once; a stopped one finds
          # them in settings.json. Launch at Login is macOS's own record and
          # needs Hex running, so it holds from the first switch after Hex
          # has been opened once.
          home.activation.hexSettings = lib.hm.dag.entryAfter (singleton "writeBoundary") ''
            if [[ -x ${hex} ]]; then
              run ${hex} settings apply ${settings} ||
                warnEcho "Hex didn't apply its settings; see the message above."
              run ${hex} launch-at-login on 2>/dev/null ||
                warnEcho "Hex isn't running, so Launch at Login waits for the next switch."
            else
              warnEcho "Hex.app isn't in ~/Applications, so its settings wait for the next switch."
            fi
          '';
        };
    };
}
