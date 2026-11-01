# The seat's boat.dev API key, for the remote build sandboxes. Scoped to
# creating and using sandboxes, so it cannot change the account. Boat is the
# stopgap until the build machine: remote-build.md in the bridge notes.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.boat-key;
  flake.nixosModules.boat-key =
    { lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship.topology) seat;
    in
    {
      users.groups.boat-key = { };
      users.users.${seat.user}.extraGroups = singleton "boat-key";

      secrets.boat-api-key = {
        file = ../../../hosts/water/secrets/boat-api-key.age;
        group = "boat-key";
        mode = "0440";
      };
    };
}
