# tuwunel Matrix homeserver, a single Rust binary on RocksDB in
# /var/lib/tuwunel. Federation is off and registration is token-gated.
#
# No public inbound port: the tailnet reaches the listener directly and
# the public hostname rides a Cloudflare Tunnel. Do NOT put a Cloudflare
# Access application on that hostname — Matrix clients speak the
# client-server API and cannot traverse an SSO wall.
#
# Egress must include the public internet even with federation off, or
# push notifications to each client's gateway stop working.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.matrix;
  flake.nixosModules.matrix =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;

      cfg = config.matrix;
      networkFences = lib.ship.fences;
    in
    {
      options.matrix = {
        enable = mkEnableOption "the family tuwunel Matrix homeserver (federation off, token-gated registration)";

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
          type = types.nullOr types.str;
          default = null;
          description = ''
            Cloudflare Tunnel connector token for the chat hostname; null =
            tailnet-only. Hostname -> http://127.0.0.1:<port> mapping is
            dashboard-side; do NOT put a Cloudflare Access app on this
            hostname (see header).
          '';
        };
      };

      config = mkIf cfg.enable {
        services.matrix-tuwunel = {
          enable = true;
          environmentFile = cfg.registrationTokenEnvFile;
          settings.global = {
            server_name = cfg.serverName;
            port = [ cfg.port ];
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
            # URL previews are off by tuwunel default; the key is not set
            # explicitly because unrecognized keys are rejected.
          };
        };

        systemd.services.tuwunel.serviceConfig = {
          # Loopback carries the cloudflared hop and resolved's stub; the
          # public internet is unmatched and so allowed, which push
          # gateways require.
          IPAddressAllow = networkFences.loopback ++ [
            "100.64.0.0/10" # tailnet clients (CGNAT range)
          ];
          IPAddressDeny = networkFences.privateRanges;
        };

        # cloudflared dials out to Cloudflare's edge; no inbound port.
        systemd.services.matrix-tunnel = mkIf (cfg.tunnelTokenFile != null) {
          description = "Cloudflare Tunnel for the Matrix homeserver";
          wantedBy = [ "multi-user.target" ];
          partOf = [ "tuwunel.service" ];
          wants = [
            "network-online.target"
            "tuwunel.service"
          ];
          after = [
            "network-online.target"
            "tuwunel.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = [ "token:${cfg.tunnelTokenFile}" ];
            ExecStart = "${getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;

            # DynamicUser bounds filesystem reach, not network reach. This
            # process needs only Cloudflare's edge and loopback (tuwunel,
            # plus resolved's stub, which /etc/resolv.conf points at so
            # cloudflared's Go resolver stays inside the fence).
            # 127.0.0.0/8 is denied because the allow is a /24.
            IPAddressAllow = networkFences.loopback;
            IPAddressDeny = networkFences.internetOnlyDeny ++ [ "127.0.0.0/8" ];
          };
          environment = {
            TUNNEL_TRANSPORT_PROTOCOL = "http2";
          };
        };
      };
    };
}
