# Mario Tennis (GBC) in the browser at https://tennis.<domain>: the exact
# Rust port from ~/hold/games/mtre, built by its web/build.sh and copied
# into the served directory by the seat. The wasm holds code translated
# from the ROM, so it stays behind the tailnet like every route; players
# supply the ROM itself, which never leaves their browser.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.tennis;
  flake.nixosModules.tennis =
    { lib, ... }:
    let
      dir = "/var/lib/tennis";
    in
    {
      shipProxy.routes.tennis.root = dir;
      systemd.tmpfiles.settings.tennis.${dir}.d = {
        user = lib.ship.topology.seat.user;
        group = "nginx";
        mode = "2750";
      };
    };
}
