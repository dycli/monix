# sudo and its @wheel password are NixOS defaults; polkit is not, and only
# the desktop session's agents need it.
{
  flake.nixosModules.desktop = {
    security.polkit.enable = true;
  };
}
