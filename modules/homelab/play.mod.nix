# Recompiled games in the browser at https://play.<domain>: a launcher with
# each game under its own path (/tennis, /earthbound), built by
# ~/hold/games/play/build.sh and copied into the served directory by the
# seat. The site holds the ROMs and code translated from them, so it stays
# behind the tailnet like every route.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.play;
  flake.nixosModules.play =
    { config, lib, ... }:
    let
      dir = "/var/lib/play";
      domain = config.shipProxy.domain;
    in
    {
      shipProxy.routes.play.root = dir;
      systemd.tmpfiles.settings.play.${dir}.d = {
        user = lib.ship.topology.seat.user;
        group = "nginx";
        mode = "2750";
      };
      # Tennis lived at its own host before the launcher.
      services.nginx.virtualHosts."tennis.${domain}" = {
        useACMEHost = domain;
        forceSSL = true;
        globalRedirect = "play.${domain}/tennis";
      };
    };
}
