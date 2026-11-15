{ self, inputs, ... }:
{
  flake.commonModules.default = self.commonModules.nix;
  flake.commonModules.nix =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.strings) getName;
    in
    {
      nix.settings = {
        experimental-features = [
          "flakes"
          "nix-command"
          "pipe-operators"
        ];

        # A trusted user can disable the build sandbox and execute as root,
        # so this excludes the primary user: syncthing.mod.nix runs
        # Syncthing as that user, listening on the tailnet. Substituters
        # below are daemon-side and still apply to everyone; a non-trusted
        # user only loses CLI overrides of restricted settings.
        trusted-users = singleton "root";

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
      nix.settings.nix-path = singleton "nixpkgs=${inputs.nixpkgs}";

      nix.channel.enable = false;

      # Scheduled optimisation; the per-write `auto-optimise-store` setting
      # slows every build and is discouraged upstream.
      nix.optimise.automatic = true;

      nix.gc = {
        automatic = true;
        options = "--delete-older-than 90d";
      };

      # Per-package unfree allowlist instead of a blanket allowUnfree. The
      # names live in `unfreePackages`, contributed by the module that
      # installs each package (see options/host.mod.nix).
      nixpkgs.config.allowUnfreePredicate = pkg: lib.lists.elem (getName pkg) config.unfreePackages;
    };

  flake.nixosModules.default = self.nixosModules.nix-linux;
  flake.nixosModules.nix-linux =
    { pkgs, ... }:
    {
      nix.gc.dates = "weekly";

      environment.systemPackages = [
        pkgs.nh
        pkgs.nix-output-monitor
      ];
    };

  # metal is shared, so its tools go to the primary user's profile, not to
  # every account's PATH.
  flake.darwinModules.default = self.darwinModules.nix-darwin;
  flake.darwinModules.nix-darwin =
    { config, pkgs, ... }:
    {
      # launchd takes a calendar interval, not a systemd calendar string:
      # Monday 00:00, which NixOS's "weekly" means.
      nix.gc.interval = {
        Weekday = 1;
        Hour = 0;
        Minute = 0;
      };

      # metal is shared: macOS's background class gives builds, and the
      # Nix daemon's other work, only what the logged-in session leaves.
      nix.daemonProcessType = "Background";

      home-manager.users.${config.primaryUser}.home.packages = [
        pkgs.nh
        pkgs.nix-output-monitor
      ];
    };
}
