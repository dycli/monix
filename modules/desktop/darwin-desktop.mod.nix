# macOS desktop defaults. nix-darwin writes these user domains through
# `launchctl asuser` for system.primaryUser alone, so another account on the
# Mac keeps its own.
{ self, ... }:
{
  flake.darwinModules.desktop = self.darwinModules.darwin-desktop;
  flake.darwinModules.darwin-desktop = {
    # DOCK
    # macOS cannot remove the Dock, so it stays empty and never slides in;
    # apps open through Spotlight and hammerspoon.mod.nix.
    system.defaults.dock = {
      autohide = true;
      autohide-delay = 1000.0;
      show-recents = false;
      persistent-apps = [ ];
      persistent-others = [ ];
      static-only = true;

      # 1 is no action.
      wvous-tl-corner = 1;
      wvous-tr-corner = 1;
      wvous-bl-corner = 1;
      wvous-br-corner = 1;
    };
  };
}
