# Hex, local voice dictation. Its window and model live per user, so it is a
# Home Manager module; the key that drives it is in hyprland/keybinds.mod.nix,
# because Hyprland's portal registers global shortcuts without a key.
{ self, inputs, ... }:
{
  flake.homeModules.desktop = self.homeModules.hex;

  flake.homeModules.hex = {
    imports = [ inputs.hex.homeManagerModules.hex ];

    programs.hex = {
      enable = true;
      autostart = true;
      installModel = true;
      settings.shortcut_mode = "toggle";
    };
  };
}
