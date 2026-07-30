# Immich — photo library with on-server ML, reached over tailscale0 at
# :2283 with no open firewall ports.
#
# Photos live in /srv/photos, separate from the media tree. The upstream
# module brings up PostgreSQL (pgvector) and Redis; ML models download
# from Hugging Face on first use.
{
  flake.nixosModules.immich =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
      networkFences = import ../../lib/network-fences.nix;
    in
    {
      config = mkIf config.services.immich.enable {
        # Upstream only auto-creates its default /var/lib location, not a
        # custom mediaLocation.
        systemd.tmpfiles.rules = [
          "d ${config.services.immich.mediaLocation} 0750 immich immich -"
        ];

        services.immich = {
          # Bind wide so the tailnet reaches :2283 directly, not only via
          # the nginx vhost.
          host = mkDefault "0.0.0.0";
          mediaLocation = mkDefault "/srv/photos";
        };

        # Public internet falls through allowed (ML model downloads,
        # reverse geocoding). 127.0.0.0/8 is named in the deny because
        # these denies are not "any", so anything unmatched is allowed.
        systemd.services.immich-server.serviceConfig = {
          IPAddressAllow = networkFences.loopback ++ [ "100.64.0.0/10" ];
          IPAddressDeny = networkFences.privateRanges ++ [ "127.0.0.0/8" ];
        };
        systemd.services.immich-machine-learning.serviceConfig = {
          IPAddressAllow = networkFences.loopback;
          IPAddressDeny = networkFences.privateRanges ++ [ "127.0.0.0/8" ];
        };

      };
    };
}
