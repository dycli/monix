# The public web role: static sites behind nginx with HTTP-01 certs. The
# fleet's one internet-facing surface — the host exposes exactly 80/443 and
# keeps admin access tailnet-only.
#
# Site content is deliberately not in the store: the site repos build locally
# and rsync to /srv/www/<domain> as the unprivileged `deploy` user.
#
# dylanc.com and su.is sit behind Cloudflare's proxy; HTTP-01 still works
# because /.well-known/acme-challenge passes to the origin over plain HTTP.
# Only the su.is apex lives here; *.su.is is the tailnet front door.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.sites;
  flake.nixosModules.sites =
    { config, lib, ... }:
    let
      inherit (lib.attrsets) genAttrs;
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;

      cfg = config.sites;

      webRoot = "/srv/www";

      live = [
        "dylanc.com"
        "su.is"
        "cleary.org"
      ];

      # Parked domains keep their certs warm and answer 503.
      parked = [ "cleary.is" ];
    in
    {
      options.sites.enable = mkEnableOption "the public static-site server";

      config = mkIf cfg.enable {
        services.nginx = {
          enable = true;
          recommendedTlsSettings = true;
          recommendedGzipSettings = true;
          recommendedOptimisation = true;

          virtualHosts =
            genAttrs live (domain: {
              forceSSL = true;
              enableACME = true;
              root = "${webRoot}/${domain}";
            })
            // genAttrs parked (domain: {
              forceSSL = true;
              enableACME = true;
              locations."/".return = "503";
            });
        };

        security.acme.acceptTerms = true;
        security.acme.defaults.email = "dylan@dylandavid.com";

        networking.firewall.allowedTCPPorts = [
          80
          443
        ];

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
