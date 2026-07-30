{ inputs, ... }:
{
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

        # Trusted Nix users are passwordless root-equivalent via the daemon:
        # a trusted user can disable the build sandbox and execute as root.
        # So the list is root and nothing else — not @wheel, and not the
        # primary user either. The primary user was here until the fourth
        # audit pointed out that Syncthing runs AS that user
        # (syncthing.mod.nix) and listens on the tailnet, which made a
        # file-sync daemon a root-equivalent process.
        #
        # Nothing normal is lost: substituters below are daemon-side config
        # and apply to every user, unprivileged builds work (the AI seat
        # builds and runs `nix flake check` all day and has never been
        # trusted), and administration goes through sudo, where root is
        # trusted. What a non-trusted user gives up is overriding restricted
        # settings from the CLI — `--option substituters …`, disabling the
        # sandbox, nominating remote builders.
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
