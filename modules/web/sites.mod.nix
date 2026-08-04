# The public web role: the family's static sites behind nginx, certs
# via HTTP-01. This is the one internet-facing surface in the fleet —
# the box carrying it exposes exactly 80/443 and keeps admin access
# tailnet-only (its host closes sshd's public port).
#
# Site content is deliberately not in the store: the site repos
# (~/hold/sites on water) build locally and rsync to /srv/www/<domain> as
# the unprivileged `deploy` user over Tailscale SSH — the same flow the
# OpenBSD predecessor used, so the deploy scripts change only their
# destination. nginx only ever reads.
#
# dylanc.com and su.is sit behind Cloudflare's proxy; HTTP-01 works
# through it because /.well-known/acme-challenge passes to the origin
# over plain HTTP. Only the su.is apex lives here — *.su.is subdomains
# are the tailnet front door (ship-proxy) or their own tunnels.
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

      # A live vhost serves its domain's deployed tree whole; su.is
      # includes /endgrain as a subdirectory of the same tree.
      live = [
        "dylanc.com"
        "su.is"
        "cleary.org"
      ];

      # Parked domains keep their certs warm but answer 503, matching
      # how the OpenBSD box parked them.
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

        # The rsync target for the deploy scripts. Tailscale SSH
        # authenticates it against the tailnet policy, so no key material
        # lives here; the policy must authorize the deploy login the same
        # way it did abra on the old box.
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
