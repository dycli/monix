# The tailnet's filtering resolver: Unbound forwarding over TLS to Quad9,
# with the hagezi Pro blocklist applied as a response policy zone. Tailnet
# devices reach it through the tailnet's global nameserver entry; LAN-only
# devices reach it through the home router, which forwards here.
#
# The blocklist is fetched from hagezi's GitLab mirror — the canonical
# GitHub repository is periodically locked by fraud-detection false
# positives — and unbound refreshes it on the zone's SOA timers (12h),
# persisting the last copy in the state directory. Until the first fetch
# completes the resolver answers unfiltered.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.resolver;
  flake.nixosModules.resolver =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) optional;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.resolver;

      # Passthru zone consulted before the blocklist: across rpz zones the
      # first match wins, in configuration order. Zone records must start
      # at column 0 — leading whitespace continues the previous owner.
      allowZone = pkgs.writeText "allow.rpz.zone" (
        ''
          $TTL 3600
          @ SOA localhost. root.localhost. 1 43200 3600 259200 3600
            NS localhost.
        ''
        + (
          cfg.allow
          |> lib.strings.concatMapStrings (d: ''
            ${d} CNAME rpz-passthru.
            *.${d} CNAME rpz-passthru.
          '')
        )
      );
    in
    {
      options.resolver = {
        enable = mkEnableOption "the tailnet filtering resolver";

        addresses = mkOption {
          type = types.listOf types.str;
          description = "Tailnet addresses to serve on, alongside loopback.";
        };

        allow = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Domains exempted from the blocklist, subdomains included.";
        };
      };

      config = mkIf cfg.enable {
        services.unbound = {
          enable = true;

          settings = {
            server = {
              interface = [
                "127.0.0.1"
                "::1"
              ]
              ++ cfg.addresses;

              access-control = [
                "127.0.0.0/8 allow"
                "::1/128 allow"
                "${fences.tailnet} allow"
                # Tailscale's fixed ULA range.
                "fd7a:115c:a1e0::/48 allow"
              ];

              # respip implements RPZ; it is not in unbound's default set.
              module-config = ''"respip validator iterator"'';

              # Strip private addresses from upstream answers (rebind
              # protection) — except under su.is, whose tailnet front door
              # publishes CGNAT addresses in public DNS by design.
              private-address = fences.privateRanges ++ [ fences.tailnet ];
              private-domain = ''"su.is"'';

              prefetch = true;
              # Answer from stale cache (up to a day) when upstream is
              # unreachable rather than failing the query.
              serve-expired = true;
              serve-expired-ttl = 86400;

              rrset-cache-size = "32m";
              msg-cache-size = "16m";

              hide-identity = true;
              hide-version = true;
            };

            rpz =
              optional (cfg.allow != [ ]) {
                name = "allow.rpz";
                zonefile = "${allowZone}";
              }
              ++ [
                {
                  name = "hagezi.pro.rpz";
                  url = "https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/rpz/pro.txt";
                  zonefile = "${config.services.unbound.stateDir}/hagezi-pro.rpz.zone";
                }
                # Public DoH servers, so clients with hardcoded DoH cannot
                # resolve their way around the filter.
                {
                  name = "hagezi.doh.rpz";
                  url = "https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/rpz/doh.txt";
                  zonefile = "${config.services.unbound.stateDir}/hagezi-doh.rpz.zone";
                }
              ];

            forward-zone = [
              {
                name = ".";
                forward-tls-upstream = true;
                forward-addr = [
                  "9.9.9.9@853#dns.quad9.net"
                  "149.112.112.112@853#dns.quad9.net"
                  "2620:fe::fe@853#dns.quad9.net"
                  "2620:fe::9@853#dns.quad9.net"
                ];
              }
            ];
          };
        };
      };
    };
}
