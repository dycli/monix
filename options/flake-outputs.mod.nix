# Types the module-aspect collections that compose hosts, so several files may
# define the same attribute and the definitions merge into one module.
#
# flake-parts types `flake.nixosModules` itself but sets no module `key`, so an
# aspect reached through two bundles would be applied twice and list options
# would double-concatenate; keying each attribute by name makes overlapping
# bundle membership dedup instead. Every `flake.homeModules` attribute is
# mirrored into the NixOS and Darwin attributes of the same name, applied to
# the host's primary user; any other managed user imports its home bundles by
# name. Every `flake.commonModules` attribute, for options both platforms
# share, is merged into the NixOS and Darwin attributes of the same name.
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
  inherit (lib.modules) mkMerge;
  inherit (lib.options) mkOption;
  inherit (lib.types) deferredModule lazyAttrsOf;

  wrap =
    kind: name: value:
    fix (module: {
      _file = "${toString moduleLocation}#${kind}.${name}";
      key = module._file;
      imports = singleton value;
    });

  primaryUserHomes =
    config.flake.homeModules
    |> mapAttrs (
      _: module:
      { config, ... }:
      {
        home-manager.users.${config.primaryUser}.imports = singleton module;
      }
    );
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

  options.flake.darwinModules = mkOption {
    type = lazyAttrsOf deferredModule;
    default = { };
    apply = mapAttrs (wrap "darwinModules");
    description = "nix-darwin aspects and bundles.";
  };

  options.flake.commonModules = mkOption {
    type = lazyAttrsOf deferredModule;
    default = { };
    apply = mapAttrs (wrap "commonModules");
    description = "Aspects and bundles that both NixOS and nix-darwin evaluate.";
  };

  options.flake.homeModules = mkOption {
    type = lazyAttrsOf deferredModule;
    default = { };
    apply = mapAttrs (wrap "homeModules");
    description = "Home Manager aspects and bundles.";
  };

  config.flake.nixosModules = mkMerge [
    config.flake.commonModules
    primaryUserHomes
  ];

  config.flake.darwinModules = mkMerge [
    config.flake.commonModules
    primaryUserHomes
  ];
}
