{
  flake.homeModules.hyprland = { lib, ... }: {
    wayland.windowManager.hyprland.extraConfig = lib.modules.mkOrder 950 (
      lib.strings.fileContents ./floating-panes.lua
    );
  };
}
