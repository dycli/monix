# sudo is on with a password for @wheel by default; polkit is not, and on a
# headless host nothing asks it anything (verified: zero authorization events
# in the journal over a week). So this aspect exists only to turn polkit ON
# for the desktop, where the session's agents genuinely need it.
{
  flake.nixosModules.sudo =
    { config, lib, ... }:
    {
      security.polkit.enable = lib.modules.mkIf config.isDesktop true;
    };
}
