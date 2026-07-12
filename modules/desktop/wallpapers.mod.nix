# Declarative wallpaper folder: the repo's wallpapers/ directory is linked
# to ~/box/pix/wallpaper (read-only store symlink). Point DMS's wallpaper
# picker there; the greeter then follows via its configHome mirror (see
# dank.mod.nix). Add or swap wallpapers by committing image files to
# wallpapers/ — the folder must be git-tracked to be visible to the flake.
{
  flake.homeModules.wallpapers =
    { lib, osConfig, ... }:
    let
      wallpaperDir = ../../wallpapers;
    in
    {
      config = lib.modules.mkIf (osConfig.isDesktop && builtins.pathExists wallpaperDir) {
        home.file."box/pix/wallpaper".source = wallpaperDir;
      };
    };
}
