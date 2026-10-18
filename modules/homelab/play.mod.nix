# Recompiled games in the browser at https://play.<domain>: a launcher with
# each game under its own path (/tennis, /earthbound), built by
# ~/hold/games/play/build.sh and copied into the served directory by the
# seat. The site holds the ROMs and code translated from them, so it stays
# behind the tailnet like every route.
#
# Saves follow a player between browsers: each browser keeps a three-word
# code, and the games PUT and GET their save at /saves/<code>/<game>.
# nginx's own WebDAV module stores them, so there is no server to run; the
# location admits only well-formed codes and the known games.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.play;
  flake.nixosModules.play =
    { config, lib, ... }:
    let
      dir = "/var/lib/play";
      saves = "/var/lib/play-saves";
      domain = config.shipProxy.domain;
    in
    {
      shipProxy.routes.play.root = dir;
      systemd.tmpfiles.settings.play.${dir}.d = {
        user = lib.ship.topology.seat.user;
        group = "nginx";
        mode = "2750";
      };
      systemd.tmpfiles.settings.play-saves.${saves}.d = {
        user = "nginx";
        group = "nginx";
        mode = "0700";
      };
      systemd.services.nginx.serviceConfig.ReadWritePaths = [ saves ];
      services.nginx.virtualHosts."play.${domain}".locations."~ ^/saves/[a-z]+-[a-z]+-[a-z]+/(tennis|earthbound|miniman)$" =
        {
          root = saves;
          extraConfig = ''
            limit_except GET PUT { deny all; }
            dav_methods PUT;
            create_full_put_path on;
            dav_access user:rw;
            client_max_body_size 1m;
            client_body_temp_path ${saves}/.part;
            add_header Cache-Control no-store always;
          '';
        };

      # Tennis lived at its own host before the launcher.
      services.nginx.virtualHosts."tennis.${domain}" = {
        useACMEHost = domain;
        forceSSL = true;
        globalRedirect = "play.${domain}/tennis";
      };
    };
}
