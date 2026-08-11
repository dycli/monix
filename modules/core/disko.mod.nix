# Declarative disk layouts (nix-community/disko). Each host declares its
# layout under `disko.devices`; disko generates the fileSystems/LUKS
# config and can format a blank disk:
#
#   nix run github:nix-community/disko -- --mode disko --flake .#<host>
#   nixos-install --flake .#<host>
#
# `nixos-rebuild switch` never formats.
{ self, inputs, ... }:
{
  flake.nixosModules.default = self.nixosModules.disko;
  flake.nixosModules.disko =
    { lib, ... }:
    {
      imports = lib.lists.singleton inputs.disko.nixosModules.disko;

      # btrfs verifies checksums only on read, so cold data is never
      # checked without a scrub. Monthly, at idle IO priority. Metadata is
      # DUP even on one device and so is repairable; file data on a single
      # device is only reported. `btrfs scrub start -B` exits non-zero on
      # uncorrectable errors, which OnFailure (alerts.mod.nix) turns into
      # an alert.
      services.btrfs.autoScrub.enable = true;
    };
}
