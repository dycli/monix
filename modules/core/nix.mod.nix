{ self, inputs, ... }:
{
  flake.nixosModules.default = self.nixosModules.nix;
  flake.nixosModules.nix =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      nix.settings = {
        experimental-features = [
          "flakes"
          "nix-command"
        ];

        # A trusted user can disable the build sandbox and execute as root,
        # so this excludes the primary user: syncthing.mod.nix runs
        # Syncthing as that user, listening on the tailnet. Substituters
        # below are daemon-side and still apply to everyone; a non-trusted
        # user only loses CLI overrides of restricted settings.
        trusted-users = [ "root" ];

        substituters = [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];

        warn-dirty = false;
      };

      # Pin the registry and NIX_PATH to this flake's nixpkgs so `nix run`,
      # `nix shell` and legacy `<nixpkgs>` lookups all resolve consistently.
      nix.registry.nixpkgs.flake = inputs.nixpkgs;
      nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

      nix.channel.enable = false;

      # Scheduled optimisation; the per-write `auto-optimise-store` setting
      # slows every build and is discouraged upstream.
      nix.optimise.automatic = true;

      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 90d";
      };

      # Per-package unfree allowlist instead of a blanket allowUnfree. The
      # names live in `unfreePackages`, contributed by the module that
      # installs each package (see options/host.mod.nix).
      nixpkgs.config.allowUnfreePredicate = pkg: lib.lists.elem (lib.getName pkg) config.unfreePackages;

      environment.systemPackages = [
        pkgs.nh
        pkgs.nix-output-monitor
      ];
    };
}
