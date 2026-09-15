# Creative applications suited to every desktop, including laptops.
{ ... }:
{
  flake.homeModules.creative =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.blender
        pkgs.inkscape
        pkgs.krita
        pkgs.gimp
        pkgs.obs-studio
        pkgs.darktable
        pkgs.ffmpeg-full
      ];
    };
}
