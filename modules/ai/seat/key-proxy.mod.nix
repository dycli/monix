# API keys the seat's tools use but must never hold. Workers run as the seat and
# can read whatever the seat can, and one key read that way already reached a
# transcript. So only root reads each key: nginx adds it to the calls a route
# allows, on a socket only the seat can reach, and refuses the rest of the API.
# Each host declares the routes for the keys it holds.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.key-proxy;
  flake.nixosModules.key-proxy =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) attrValues mapAttrsToList;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkBefore mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStrings concatStrings;
      inherit (lib.ship.topology) seat;
      inherit (lib) types;

      routes = config.keyProxy.routes;
      directory = "/run/key-proxy";
      header = name: "/run/nginx/key-proxy-${name}.conf";

      # The key file is bare; the header line around it is written here.
      writeHeaders = pkgs.writeShellApplication {
        name = "write-key-proxy-headers";
        runtimeInputs = [
          pkgs.acl
          pkgs.coreutils
        ];
        text = ''
          umask 077
          ${concatStrings (
            mapAttrsToList (name: route: ''
              if key=$(cat ${config.secrets.${route.secret}.path}); then
                printf 'proxy_set_header %s "%s%s";\n' ${route.header} ${lib.escapeShellArg route.prefix} "$key" > ${header name}
                chown nginx:nginx ${header name}
              fi
            '') routes
          )}
          # An entry, not chgrp: systemd puts a runtime directory back to the unit's
          # owner before each later start step, and an access entry stays through that.
          setfacl -m u:${seat.user}:x ${directory}
        '';
      };

      server = name: route: ''
        # Matched on the raw URI, as the upstream sees the request.
        map "$request_method $request_uri" $key_proxy_${name} {
          default 0;
          ${concatMapStrings (call: ''"${call}" 1;'' + "\n") route.allow}
        }

        server {
          listen unix:${directory}/${name}.sock;
          default_type application/json;
          resolver 127.0.0.53 ipv6=off;

          location / {
            if ($key_proxy_${name} = 0) {
              return 403 '{"code":"not_allowed","message":"the key proxy allows no such call"}';
            }

            # A variable, so nginx resolves the name per request: a literal
            # host that fails to resolve at start stops every site.
            set $upstream_${name} ${route.host};
            proxy_pass https://$upstream_${name};
            proxy_ssl_server_name on;
            proxy_ssl_verify on;
            proxy_ssl_verify_depth 3;
            proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
            proxy_set_header Host ${route.host};
            # Replaces whatever the caller sent in the header. A pattern, which may
            # match nothing: if the key fails to decrypt, the upstream answers 401
            # here and the sites stay up.
            include /run/nginx/key-proxy-${name}*.conf;
          }
        }
      '';
    in
    {
      options.keyProxy.routes = mkOption {
        default = { };
        description = "Upstream APIs reached through a key root holds, one socket each at ${directory}/<name>.sock.";
        type = types.attrsOf (
          types.submodule {
            options = {
              host = mkOption {
                type = types.str;
                description = "The upstream's host name, reached over HTTPS.";
              };
              secret = mkOption {
                type = types.str;
                description = "The name under `secrets` of the file holding the bare key.";
              };
              header = mkOption {
                type = types.str;
                default = "Authorization";
                description = "The header the key goes in.";
              };
              prefix = mkOption {
                type = types.str;
                default = "Bearer ";
                description = "What precedes the key in the header.";
              };
              allow = mkOption {
                type = types.listOf types.str;
                description = ''
                  The calls allowed, as nginx map keys over "$request_method $request_uri":
                  a literal, or a regex starting with ~.
                '';
              };
            };
          }
        );
      };

      config = mkIf (routes != { }) {
        services.nginx.appendHttpConfig = concatStrings (mapAttrsToList server routes);

        systemd.services.nginx = {
          restartTriggers = map (route: config.secrets.${route.secret}.file) (attrValues routes);
          serviceConfig = {
            # A runtime directory goes when nginx stops, however it stops: a socket
            # left by a killed nginx would refuse the next start, and every site with it.
            RuntimeDirectory = singleton "key-proxy";
            # + for root, which alone reads the keys; - so a failure here leaves
            # nginx to start without them.
            ExecStartPre = mkBefore (singleton "+-${getExe writeHeaders}");
          };
        };
      };
    };
}
