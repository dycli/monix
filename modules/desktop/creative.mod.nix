# Creative applications for video, graphics, photography, and streaming.
{ self, ... }:
{
  flake.nixosModules.creative =
    { lib, ... }:
    {
      unfreePackages = lib.lists.singleton "davinci-resolve";
    };

  flake.homeModules.creative =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.davinci-resolve
        pkgs.blender
        pkgs.inkscape
        pkgs.krita
        pkgs.gimp
        pkgs.obs-studio
        pkgs.darktable
      ];
    };
}
