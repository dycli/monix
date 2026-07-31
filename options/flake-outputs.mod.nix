# Declares the module-aspect collections used to compose hosts, typed so
# that several files may define the same attribute and the definitions
# merge into one module — the bundle mechanism (adapted from rgbcube/ncc):
#
#   flake.nixosModules.desktop = self.nixosModules.audio;
#
# flake-parts types `flake.nixosModules` this way itself, but its wrapper
# sets no module `key`, so an aspect reached through two bundles would be
# applied twice and list options would double-concatenate. The
# re-declaration below wraps every attribute with a key derived from its
# name, making overlapping bundle membership dedup instead.
#
# `flake.homeModules` gets the same typing, and every home attribute is
# mirrored into the NixOS attribute of the same name via
# home-manager.sharedModules — importing a bundle brings its home aspects
# for every managed user on the host.
{
  config,
  inputs,
  lib,
  moduleLocation,
  ...
}:
let
  inherit (lib.attrsets) mapAttrs;
  inherit (lib.fixedPoints) fix;
  inherit (lib.lists) singleton;
  inherit (lib.options) mkOption;
  inherit (lib.types) deferredModule lazyAttrsOf;

  wrap =
    kind: name: value:
    fix (module: {
      _file = "${toString moduleLocation}#${kind}.${name}";
      key = module._file;
      imports = singleton value;
    });
in
{
  # flake-parts' own declaration wraps without a key; replace it.
  disabledModules = singleton "${inputs.flake-parts}/modules/nixosModules.nix";

  options.flake.nixosModules = mkOption {
    type = lazyAttrsOf deferredModule;
    default = { };
    apply = mapAttrs (wrap "nixosModules");
    description = "NixOS aspects and bundles.";
  };

  options.flake.homeModules = mkOption {
    type = lazyAttrsOf deferredModule;
    default = { };
    apply = mapAttrs (wrap "homeModules");
    description = "Home Manager aspects and bundles.";
  };

  config.flake.nixosModules = mapAttrs (_: module: {
    home-manager.sharedModules = singleton module;
  }) config.flake.homeModules;
}
