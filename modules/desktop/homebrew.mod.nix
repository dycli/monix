# Homebrew for the macOS applications nixpkgs lacks or cannot sign. The
# prefix is machine-wide, and each cask installs into the primary user's
# ~/Applications, so another account sees none of them.
{ self, inputs, ... }:
{
  flake.darwinModules.desktop = self.darwinModules.homebrew;
  flake.darwinModules.homebrew =
    { config, lib, ... }:
    let
      inherit (lib.attrsets) attrNames;
      inherit (lib.lists) singleton;
    in
    {
      imports = singleton inputs.nix-homebrew.darwinModules.nix-homebrew;

      nix-homebrew = {
        enable = true;
        user = config.primaryUser;

        # Read-only taps from the lock: a switch installs the cask versions
        # the lock names, and nothing taps or updates behind it.
        mutableTaps = false;
        taps = {
          "homebrew/homebrew-core" = inputs.homebrew-core;
          "homebrew/homebrew-cask" = inputs.homebrew-cask;
          "anomalyco/homebrew-tap" = inputs.homebrew-anomalyco;
        };

        # The integrations write /etc/zshrc and the others, which every
        # account reads; the primary user's casks need no brew on PATH.
        enableBashIntegration = false;
        enableFishIntegration = false;
        enableZshIntegration = false;
      };

      homebrew = {
        enable = true;

        # brew bundle then finds every tap already present.
        taps = attrNames config.nix-homebrew.taps;

        caskArgs.appdir = "~/Applications";

        # A switch installs what is missing and leaves the rest: casks the
        # user installs by hand stay, and each app keeps its own updater.
        onActivation = {
          cleanup = "none";
          autoUpdate = false;
          upgrade = false;
        };
      };
    };
}
