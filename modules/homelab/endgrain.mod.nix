# Endgrain's staff schedule at https://endgrain.<domain>: ./endgrain lays
# out each week's shifts, posts them, and takes staff requests. The tailnet
# reaches it through the shared proxy, staff through a Cloudflare Tunnel.
# The app asks for a password itself (staff or manager) on every path, so
# the tunnel passes everything through.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.endgrain;
  flake.nixosModules.endgrain =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      port = 8980;
      endgrain = lib.ship.rustTool pkgs { src = ./endgrain; };
      tokenFile = config.endgrain.tunnelTokenFile;
    in
    {
      options.endgrain.tunnelTokenFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Cloudflare Tunnel connector token for the staff door; null =
          tailnet-only. The hostname -> http://127.0.0.1:${toString port}
          mapping is dashboard-side.
        '';
      };

      config = {
        shipProxy.routes.endgrain.port = port;

        users.users.endgrain = {
          isSystemUser = true;
          group = "endgrain";
        };
        users.groups.endgrain = { };

        systemd.services.endgrain = {
          description = "Endgrain's staff schedule";
          wantedBy = singleton "multi-user.target";
          environment = {
            ENDGRAIN_LISTEN = "127.0.0.1:${toString port}";
            ENDGRAIN_STATE = "%S/endgrain";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = "endgrain";
            Group = "endgrain";
            StateDirectory = "endgrain";
            ExecStart = getExe endgrain;
            Restart = "on-failure";
            SocketBindDeny = "any";
            SocketBindAllow = singleton "tcp:${toString port}";
            # It talks to nobody; nginx and the tunnel reach it over loopback.
            IPAddressAllow = fences.loopback;
            IPAddressDeny = "any";
          };
        };

        systemd.services.endgrain-tunnel = mkIf (tokenFile != null) {
          description = "Cloudflare Tunnel for Endgrain's staff";
          wantedBy = singleton "multi-user.target";
          wants = singleton "network-online.target";
          after = [
            "network-online.target"
            "endgrain.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = singleton "token:${tokenFile}";
            ExecStart = "${getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
            # Cloudflare's edge and loopback only; 127.0.0.0/8 is denied
            # because the allow is a /24.
            IPAddressAllow = fences.loopback;
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          };
          environment.TUNNEL_TRANSPORT_PROTOCOL = "http2";
        };
      };
    };
}
