# Push for phones without Google at https://push.<domain> (tailnet only):
# ntfy, the UnifiedPush server. A phone's ntfy app holds one connection here
# and wakes the apps that registered with it (Libri first); a server such as
# Libri posts to the endpoint the phone gave it. Like every ship service the
# tailnet is the gate, so ntfy keeps no accounts. Messages wait in its cache
# for a phone that was off the tailnet when they were sent.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.push;
  flake.nixosModules.push =
    { config, lib, ... }:
    let
      inherit (lib.ship) fences;
      port = 8991;
    in
    {
      shipProxy.routes.push = {
        inherit port;
        # Phones hold their subscription open; nginx's default 60s read
        # timeout would cut it each minute.
        proxyExtra = ''
          proxy_buffering off;
          proxy_read_timeout 1h;
        '';
      };

      services.ntfy-sh = {
        enable = true;
        settings = {
          base-url = "https://push.${config.shipProxy.domain}";
          listen-http = "127.0.0.1:${toString port}";
          behind-proxy = true;
        };
      };

      # Reached only through nginx; it never calls out.
      systemd.services.ntfy-sh.serviceConfig = {
        IPAddressAllow = fences.loopback;
        IPAddressDeny = "any";
      };
    };
}
