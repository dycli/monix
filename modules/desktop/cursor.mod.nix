# Pointer cursor theme. x11.enable materializes the theme under ~/.icons,
# which XWayland clients and Steam's pressure-vessel runtime read — env vars
# alone (hyprland's env.mod.nix) don't reach them.
{ self, ... }:
{
  flake.homeModules.desktop = self.homeModules.cursor;
  flake.homeModules.cursor =
    { pkgs, ... }:
    {
      home.pointerCursor = {
        enable = true;
        package = pkgs.bibata-cursors;
        name = "Bibata-Modern-Amber";
        size = 24;
        gtk.enable = true;
        x11.enable = true;
      };
    };
}
