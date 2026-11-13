# tuwunel Matrix homeserver, a single Rust binary on RocksDB in
# /var/lib/tuwunel. Federation is off and registration is token-gated.
#
# No public inbound port: the tailnet reaches the listener directly and
# the public hostname rides a Cloudflare Tunnel. That hostname must carry
# no Cloudflare Access application — Matrix clients speak the
# client-server API and cannot traverse an SSO wall. Egress must include
# the internet even with federation off, or push notifications stop.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.matrix;
  flake.nixosModules.matrix =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.options) mkOption;
      inherit (lib) types;

      cfg = config.matrix;
      inherit (lib.ship) fences;
    in
    {
      options.matrix = {
        serverName = mkOption {
          type = types.str;
          example = "chat.example.com";
          description = ''
            The Matrix server_name — the domain in every user id
            (@max:<serverName>) AND the hostname clients type at login, so
            it must equal the public hostname served by the tunnel. Baked
            into the database on first start; changing it later means
            starting over.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 6167;
          description = ''
            Client-API listen port (tuwunel's default). The Cloudflare
            public hostname must target this port.
          '';
        };

        registrationTokenEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix-managed environment file containing
            TUWUNEL_REGISTRATION_TOKEN=<token> — the only way to create an
            account on this server. Rotate by re-encrypting the secret.
          '';
        };

        tunnelTokenFile = mkOption {
          type = types.str;
          description = ''
            Cloudflare Tunnel connector token for the chat hostname.
            Hostname -> http://127.0.0.1:<port> mapping is
            dashboard-side; do NOT put a Cloudflare Access app on this
            hostname (see header).
          '';
        };
      };

      config = {
        services.matrix-tuwunel = {
          enable = true;
          # nixpkgs' cargo hook now makes Rust builds use system aws-lc and
          # jemalloc, and the tuwunel package (f4a03c0) supplies neither, so
          # its build panics. aws-lc is added; jemalloc is turned off, which
          # leaves the system allocator, ample for a two-user server. Remove
          # once nixpkgs fixes matrix-tuwunel.
          package = (pkgs.matrix-tuwunel.override { enableJemalloc = false; }).overrideAttrs (old: {
            buildInputs = old.buildInputs ++ singleton pkgs.aws-lc;
          });
          environmentFile = cfg.registrationTokenEnvFile;
          settings.global = {
            server_name = cfg.serverName;
            port = singleton cfg.port;
            # Bind everywhere; reachability is the firewall's job.
            address = [
              "0.0.0.0"
              "::"
            ];
            allow_federation = false;
            allow_registration = true; # token-gated via the env secret
            allow_encryption = true;
            # tuwunel otherwise appends "💕" to new display names.
            new_user_displayname_suffix = "";
            trusted_servers = [ ];
            # URL previews stay off by default; the key is not set
            # explicitly because unrecognized keys are rejected.
          };
        };

        systemd.services.tuwunel.serviceConfig = {
          # Loopback carries the cloudflared hop and resolved's stub; the
          # internet is unmatched and so allowed, which push gateways need.
          IPAddressAllow = fences.loopback ++ singleton fences.tailnet;
          IPAddressDeny = fences.privateRanges;
        };

        systemd.services.matrix-tunnel =
          lib.ship.tunnel pkgs {
            description = "Cloudflare Tunnel for the Matrix homeserver";
            tokenFile = cfg.tunnelTokenFile;
            backend = "tuwunel.service";
          }
          // {
            partOf = singleton "tuwunel.service";
          };
      };
    };
}
