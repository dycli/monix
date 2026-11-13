# An outbound Cloudflare tunnel in front of one local service: its routes
# (hostname to loopback port) live in the tunnel's remote configuration at
# Cloudflare, so the host opens no public port.
lib: pkgs:
{
  description,
  tokenFile,
  backend,
}:
let
  inherit (lib.lists) singleton;
  inherit (lib.ship) fences;
  needs = [
    "network-online.target"
    backend
  ];
in
{
  inherit description;
  wantedBy = singleton "multi-user.target";
  wants = needs;
  after = needs;
  serviceConfig = {
    DynamicUser = true;
    LoadCredential = singleton "token:${tokenFile}";
    ExecStart = "${lib.meta.getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
    Restart = "always";
    RestartSec = 5;
    # Cloudflare's edge and loopback only; 127.0.0.0/8 is denied because
    # the allow is a /24.
    IPAddressAllow = fences.loopback;
    IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
  };
  environment.TUNNEL_TRANSPORT_PROTOCOL = "http2";
}
