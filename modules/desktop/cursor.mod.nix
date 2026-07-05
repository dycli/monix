# Pointer cursor theme. Without an installed theme, XCURSOR_THEME points at
# nothing and every toolkit falls back to the ancient X11 left-ptr look.
# home.pointerCursor installs the theme and wires it into GTK, X resources,
# and hyprcursor in one place; the matching env vars for the Hyprland session
# itself are set in hyprland.mod.nix (uwsm finalize exports them).
{
  flake.homeModules.cursor =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf osConfig.isDesktop {
        home.pointerCursor = {
          package = pkgs.bibata-cursors;
          name = "Bibata-Modern-Classic";
          size = 24;
          gtk.enable = true;
          x11.enable = true;
          hyprcursor.enable = true;
        };
      };
    };
}
