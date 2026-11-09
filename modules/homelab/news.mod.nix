# The feed reader at https://news.<domain> (tailnet only): Miniflux, on the
# host's Postgres. It fetches feeds from the internet and serves one reading
# list. Like every ship service the tailnet is the gate, so nginx names the
# reader on every page request and Miniflux keeps no login of its own. Phone
# apps use the Google Reader API, whose username and password are set in
# Settings → Integrations; that API ignores the header.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.news;
  flake.nixosModules.news =
    { config, lib, ... }:
    let
      inherit (lib.ship) fences;

      port = 8990;
      reader = "dylan";
      header = "X-Remote-User";
    in
    {
      shipProxy.routes.news = {
        inherit port;
        # Set by nginx on every request, so a client cannot choose it.
        proxyExtra = "proxy_set_header ${header} ${reader};";
      };

      services.miniflux = {
        enable = true;
        config = {
          LISTEN_ADDR = "127.0.0.1:${toString port}";
          BASE_URL = "https://news.${config.shipProxy.domain}/";
          CREATE_ADMIN = false;
          DISABLE_LOCAL_AUTH = 1;
          AUTH_PROXY_HEADER = header;
          AUTH_PROXY_USER_CREATION = 1;
          TRUSTED_REVERSE_PROXY_NETWORKS = "127.0.0.1/32";
        };
      };

      systemd.services.miniflux.serviceConfig = {
        # Feeds on the internet and nginx on loopback; the LAN and tailnet stay shut.
        IPAddressAllow = fences.loopback;
        IPAddressDeny = fences.internetOnlyDeny;
      };
    };
}
