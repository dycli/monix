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
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) mkOption types;
      inherit (lib.ship) fences;
      cfg = config.news;

      port = 8990;
      reader = "dylan";
      header = "X-Remote-User";
      keysDir = "/var/lib/news-keys";
      psql = "${config.services.postgresql.package}/bin/psql";
    in
    {
      options.news.apiKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Services that read the feeds over the Miniflux API, each named by
          its systemd unit. Each gets a key in ${keysDir}/<name>, made on
          this host and never stored elsewhere, ready before the unit starts.
        '';
      };

      config = {
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

        # Keys made here rather than in agenix: they never leave this host.
        # The reader's account appears on its first visit to the site, so
        # until then the key is written but not yet in Miniflux; the next run
        # (any deploy or reboot) adds it.
        systemd.services.news-keys = lib.mkIf (cfg.apiKeys != [ ]) {
          description = "Miniflux API keys for the services that read the feeds";
          requires = [ "miniflux.service" ];
          after = [ "miniflux.service" ];
          before = map (n: "${n}.service") cfg.apiKeys;
          wantedBy = map (n: "${n}.service") cfg.apiKeys;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = config.services.postgresql.superUser;
            StateDirectory = "news-keys";
            StateDirectoryMode = "0700";
            UMask = "0077";
          };
          path = [ pkgs.openssl ];
          script = lib.concatMapStrings (n: ''
            f=${keysDir}/${n}
            [ -s "$f" ] || openssl rand -hex 32 > "$f"
            ${psql} -v ON_ERROR_STOP=1 -d miniflux -v token="$(cat "$f")" <<'SQL'
            INSERT INTO api_keys (user_id, token, description)
              SELECT id, :'token', '${n}' FROM users WHERE username = '${reader}'
              ON CONFLICT (user_id, description) DO UPDATE SET token = EXCLUDED.token;
            SQL
          '') cfg.apiKeys;
        };
      };
    };
}
