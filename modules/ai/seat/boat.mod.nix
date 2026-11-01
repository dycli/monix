# The boat.dev API key, for the remote build sandboxes. Workers run as the seat
# and can read whatever the seat can, and one key read that way already reached
# a transcript. So only root holds the key: nginx adds it to the calls remote_run
# makes, on a socket only the seat can reach, and refuses the rest of boat's API.
# Boat is the stopgap until the build machine: remote-build.md in the bridge notes.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.boat-key;
  flake.nixosModules.boat-key =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) getExe;
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkBefore;
      inherit (lib.ship.topology) seat;

      secret = config.secrets.boat-api-key;

      authorization = "/run/nginx/boat-authorization.conf";
      writeAuthorization = pkgs.writeShellApplication {
        name = "write-boat-authorization";
        runtimeInputs = [
          pkgs.acl
          pkgs.coreutils
        ];
        text = ''
          umask 077
          printf 'proxy_set_header Authorization "Bearer %s";\n' "$(cat ${secret.path})" > ${authorization}
          chown nginx:nginx ${authorization}
          # An entry, not chgrp: systemd puts a runtime directory back to the unit's
          # owner before each later start step, and an access entry stays through that.
          setfacl -m u:${seat.user}:x /run/boat-proxy
        '';
      };
    in
    {
      secrets.boat-api-key.file = ../../../hosts/water/secrets/boat-api-key.age;

      # Boat sees the request as sent, so the match is on the raw URI, not the
      # normalised one.
      services.nginx.appendHttpConfig = ''
        map "$request_method $request_uri" $boat_call {
          default 0;
          "~^GET /api/v1/sandboxes(\?\S*)?$" 1;
          "POST /api/v1/sandboxes" 1;
          "~^(GET|DELETE) /api/v1/sandboxes/[\w-]+$" 1;
          "~^POST /api/v1/sandboxes/[\w-]+/sshkey$" 1;
          "~^GET /api/v1/sandboxes/[\w-]+/usage$" 1;
          "POST /api/v1/saved-snapshots" 1;
          "~^GET /api/v1/saved-snapshots/[\w-]+$" 1;
        }

        server {
          listen unix:/run/boat-proxy/boat.sock;
          default_type application/json;
          resolver 127.0.0.53 ipv6=off;

          location / {
            if ($boat_call = 0) {
              return 403 '{"code":"not_allowed","message":"remote_run makes no such call"}';
            }

            # A variable, so nginx resolves the name per request: a literal
            # host that fails to resolve at start stops every site.
            set $boat boat.dev;
            proxy_pass https://$boat;
            proxy_ssl_server_name on;
            proxy_ssl_verify on;
            proxy_ssl_verify_depth 3;
            proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
            proxy_set_header Host boat.dev;
            # A pattern, which may match nothing: if the key fails to decrypt, boat
            # answers 401 here and the sites stay up.
            include /run/nginx/boat-authorization*.conf;
          }
        }
      '';

      systemd.services.nginx = {
        restartTriggers = singleton secret.file;
        serviceConfig = {
          # A runtime directory goes when nginx stops, however it stops: a socket
          # left by a killed nginx would refuse the next start, and every site with it.
          RuntimeDirectory = singleton "boat-proxy";
          # + for root, which alone reads the key; - so a failure here leaves
          # nginx to start without it.
          ExecStartPre = mkBefore (singleton "+-${getExe writeAuthorization}");
        };
      };
    };
}
