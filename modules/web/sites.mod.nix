# The public web role: static sites behind nginx, reached only through an
# outbound Cloudflare tunnel. The host opens no public port: Cloudflare's edge
# holds the certificates and speaks plain HTTP to nginx on loopback, and
# admin access is tailnet-only.
#
# Site content is deliberately not in the store: the site repos build locally
# and rsync to /srv/www/<domain> as the unprivileged `deploy` user.
#
# Only the su.is apex lives here; *.su.is is the tailnet front door.
{ self, ... }:
{
  flake.nixosModules.web = self.nixosModules.sites;
  flake.nixosModules.sites =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) genAttrs listToAttrs nameValuePair;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.ship) fences;
      tokenFile = config.web.tunnelTokenFile;

      webRoot = "/srv/www";

      live = [
        "dylanc.com"
        "su.is"
        "cleary.org"
      ];

      # Other names of ours send visitors to dylanc.com, path kept.
      redirected = [
        "cleary.is"
        "dylandavid.com"
      ];

      extra = {
        # su.is keeps its small projects under /labs/; the old top-level
        # paths send visitors there.
        # Its files keep fixed names across deploys, so browsers must
        # revalidate every load (a cheap 304) or they run a stale lab; a file
        # asked for with ?v= is the exception (see $suis_cache below).
        "su.is" = {
          locations."~ ^/(endgrain|lifespan|liberi)(/|$)".return = "301 /labs$request_uri";
          extraConfig = "add_header Cache-Control $suis_cache;";
        };
        # lfish writes each file's page as <path>.html and content-hashes
        # everything under /_/.
        "dylanc.com" = {
          locations."/".tryFiles = "$uri $uri.html $uri/index.html =404";
          locations."/_/".extraConfig = "expires max;";
          extraConfig = "error_page 404 /404.html;";
        };
      };
    in
    {
      options.web.tunnelTokenFile = lib.options.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Token of the Cloudflare tunnel that carries the public sites to nginx.";
      };

      config = {
        # Cloudflare's edge reaches nginx through this outbound tunnel; its
        # routes (hostname to loopback port) live in the tunnel's remote
        # configuration at Cloudflare.
        systemd.services.web-tunnel = mkIf (tokenFile != null) {
          description = "Cloudflare Tunnel for the public sites";
          wantedBy = singleton "multi-user.target";
          wants = singleton "network-online.target";
          after = [
            "network-online.target"
            "nginx.service"
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

        services.nginx = {
          enable = true;
          # The tunnel is the only client; nothing listens beyond loopback.
          defaultListen = singleton {
            addr = "127.0.0.1";
            port = 80;
          };
          recommendedGzipSettings = true;
          recommendedOptimisation = true;

          # The labs' pages bump an asset's ?v= whenever the file changes, so
          # a versioned URL never changes content and caches for a year, at
          # Cloudflare's edge as well as in the browser.
          appendHttpConfig = ''
            map $arg_v $suis_cache {
              "" no-cache;
              default "public, max-age=31536000, immutable";
            }
          '';

          virtualHosts =
            genAttrs live (
              domain:
              {
                root = "${webRoot}/${domain}";
              }
              // extra.${domain} or { }
            )
            // (
              redirected
              |> map (
                domain:
                nameValuePair domain {
                  serverAliases = singleton "www.${domain}";
                  locations."/".return = "301 https://dylanc.com$request_uri";
                }
              )
              |> listToAttrs
            )
            # www.<domain> answers with a 301 to the bare name, path kept,
            # so the bar drops the www. The scheme is written out: nginx
            # sees plain HTTP from the tunnel, while visitors arrive over
            # HTTPS at Cloudflare's edge.
            // (
              live
              |> map (
                domain:
                nameValuePair "www.${domain}" {
                  locations."/".return = "301 https://${domain}$request_uri";
                }
              )
              |> listToAttrs
            );
        };

        # The rsync target for the deploy scripts. Tailscale SSH authenticates
        # it against the tailnet policy, so no key material lives here.
        users.groups.deploy = { };
        users.users.deploy = {
          isNormalUser = true;
          description = "site deployments";
          group = "deploy";
        };

        # Deploy owns the trees; 0755 keeps them readable by nginx.
        systemd.tmpfiles.rules =
          singleton "d ${webRoot} 0755 deploy deploy -"
          ++ map (domain: "d ${webRoot}/${domain} 0755 deploy deploy -") live;
      };
    };
}
