# Exposes the admin SSH public keys from ./keys.nix as a flake output so
# modules can reference them (e.g. for authorizedKeys). `self.keys-admin`.
let
  keys = import ../../keys.nix;
in
{
  flake.keys-admin = keys.admin;
}
