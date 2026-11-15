# The iOS and macOS build role: a Mac that Water's workers drive over SSH.
{ self, ... }:
{
  flake.darwinModules.apple-build = self.darwinModules.stay-awake;

  # A build or deploy from Water needs the Mac reachable, so on the charger it
  # never sleeps while idle; the display still sleeps on macOS's own timer.
  # pmset is used directly because nix-darwin's power.sleep.computer goes
  # through systemsetup, which sets battery as well. The setting is
  # machine-wide, for every account (docs/darwin-plan.md §9).
  flake.darwinModules.stay-awake = {
    system.activationScripts.postActivation.text = ''
      /usr/bin/pmset -c sleep 0
    '';
  };
}
