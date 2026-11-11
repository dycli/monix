# The boat.dev API key, for the remote build sandboxes, reached only through the
# key proxy: the calls remote_run makes and no others.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.boat-key;
  flake.nixosModules.boat-key = {
    secrets.boat-api-key.file = ../../../hosts/water/secrets/boat-api-key.age;

    keyProxy.routes.boat = {
      host = "boat.dev";
      secret = "boat-api-key";
      allow = [
        ''~^GET /api/v1/sandboxes(\?\S*)?$''
        "POST /api/v1/sandboxes"
        ''~^(GET|DELETE) /api/v1/sandboxes/[\w-]+$''
        ''~^POST /api/v1/sandboxes/[\w-]+/sshkey$''
        ''~^GET /api/v1/sandboxes/[\w-]+/usage$''
        "POST /api/v1/saved-snapshots"
        ''~^GET /api/v1/saved-snapshots/[\w-]+$''
      ];
    };
  };
}
