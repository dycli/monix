# metal — a MacBook Air (Apple silicon) shared with a second macOS account,
# whose side nothing here may change: per-user settings go to the primary
# user only, and each machine-wide one is listed in docs/darwin-plan.md.
{ self, lib, ... }:
{
  imports = lib.lists.singleton (
    lib.ship.darwinHost "metal" (
      { config, ... }:
      {
        # The editors alone from `dev`: its toolchain comes with Libri's
        # devShell, and its gcc would shadow Apple's clang.
        imports = lib.lists.singleton self.darwinModules.editors;

        # The macOS short name, as `whoami` prints it on the Mac.
        primaryUser = "dylan";

        nixpkgs.hostPlatform = "aarch64-darwin";

        system.stateVersion = 7;
        home-manager.users.${config.primaryUser}.home.stateVersion = "26.11";
      }
    )
  );
}
