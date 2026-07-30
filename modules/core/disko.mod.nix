# Declarative disk layouts (nix-community/disko). Each host declares its
# layout under `disko.devices` in its host module; disko generates the
# `fileSystems`/LUKS mount config from it and can format a blank disk to
# match:
#
#   nix run github:nix-community/disko -- --mode disko --flake .#<host>
#   nixos-install --flake .#<host>
#
# `nixos-rebuild switch` never formats — formatting only happens via the
# explicit disko command above.
#
# Both hosts put / on btrfs, so this aspect also carries the one piece of
# btrfs hygiene that costs nothing: a periodic scrub.
{ inputs, ... }:
{
  flake.nixosModules.disko = {
    imports = [ inputs.disko.nixosModules.disko ];

    # btrfs checksums everything it writes but only VERIFIES on read, so
    # without this nothing ever checks data that is not being read — and
    # silent corruption surfaces whenever someone finally opens the file,
    # possibly years later. Monthly, at idle IO priority.
    #
    # Metadata is DUP even on a single device, so a scrub genuinely REPAIRS
    # metadata corruption from the second copy. File data on one device it
    # cannot repair, but it names the damaged file instead of quietly
    # serving corrupt bytes — and when the RAID array lands, the same unit
    # starts repairing data too.
    #
    # This is also how the owner finds out: `btrfs scrub start -B` exits
    # non-zero on uncorrectable errors, so the unit fails, and the
    # OnFailure drop-ins from alerts.mod.nix turn that into a Matrix
    # alert. Complements smartd, which watches whether the DRIVE is dying
    # rather than whether the DATA is.
    services.btrfs.autoScrub.enable = true;
  };
}
