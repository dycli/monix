# Matrix homeserver aspect — the family chat rail (rooms are the UI; bots
# are just other accounts). tuwunel: a single Rust binary on RocksDB.
# Inert until a host sets `matrix.enable`.
#
# Deliberately not a public Matrix node:
#   - allow_federation = false — this server speaks to no other
#     homeserver, removing the federation attack/abuse surface.
#   - Registration is token-gated, permanently: an account can only be
#     created with the registration token (agenix env secret).
#   - E2EE stays allowed but family rooms are intended unencrypted:
#     transport is TLS into our own hardware, and skipping E2EE avoids
#     device-verification friction and keeps bot integration simple.
#
# No public inbound port; tailnet reaches the listener directly and the
# public hostname rides a dedicated Cloudflare Tunnel. NO Cloudflare
# Access application on this hostname — Matrix clients speak the
# client-server API and cannot traverse an Access SSO wall; auth is
# Matrix's own password login plus the token-gated registration above.
#
# Egress must include the public internet — federation is off, but phone
# notifications require the homeserver to call each client's push gateway
# (Element's sygnal at matrix.org); block that and mobile push silently
# dies. Fence shape: public allowed; loopback pinholes, LAN, and fleet
# bridge denied.
#
# Data: /var/lib/tuwunel (RocksDB), service-private — include it in the
# off-host backup design.
{
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
      networkFences = import ../../lib/network-fences.nix;
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
          type = types.path;
          description = ''
            agenix-managed environment file containing
            TUWUNEL_REGISTRATION_TOKEN=<token> — the only way to create an
            account on this server. Rotate by re-encrypting the secret.
          '';
        };

        tunnelTokenFile = mkOption {
          type = types.nullOr types.path;
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
            # The three load-bearing policy switches (see header).
            allow_federation = false;
            allow_registration = true; # token-gated via the env secret
            allow_encryption = true;
            # tuwunel's default appends "💕" to every new account's display
            # name; existing accounts keep whatever name they have.
            new_user_displayname_suffix = "";
            # Federation is off; don't name notary key servers at all.
            trusted_servers = [ ];
            # URL previews (SSRF-shaped) are off by tuwunel default; the
            # exact key isn't set explicitly since unrecognized keys are
            # rejected and it's unverifiable from the stripped binary.
          };
        };

        systemd.services.tuwunel.serviceConfig = {
          # Count chat against the general services fence.
          Slice = "services.slice";

          # Public internet stays reachable (push gateways — notifications
          # die without it) but LAN and the fleet bridge do not. Loopback
          # is allowed: cloudflared delivers every public client over
          # 127.0.0.1, and systemd's IP filter can't distinguish that
          # inbound hop from outbound loopback use. systemd checks Allow
          # before Deny; unmatched = allowed (public).
          IPAddressAllow = [
            "127.0.0.0/8" # the cloudflared hop (and resolved's DNS stub)
            "::1"
            "100.64.0.0/10" # tailnet clients (CGNAT range)
          ];
          IPAddressDeny = networkFences.privateRanges;
        };

        # Public web ingress: a dedicated cloudflared connector that dials out
        # to Cloudflare's edge; no inbound port.
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
          };
          environment = {
            TUNNEL_TRANSPORT_PROTOCOL = "http2";
          };
        };
      };
    };
}
