# Declares the module-aspect collections used to compose hosts.
#
# `flake.nixosModules` is provided by flake-parts itself. We declare a matching
# collection for Home Manager aspects applied to the primary user.
{ lib, ... }:
let
  inherit (lib.options) mkOption;
  inherit (lib.types) deferredModule lazyAttrsOf;
in
{
  options.flake.homeModules = mkOption {
    type = lazyAttrsOf deferredModule;
    default = { };
    description = "Home Manager modules applied to the primary user.";
  };
}
