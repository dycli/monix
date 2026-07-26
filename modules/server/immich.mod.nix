# Immich aspect — self-hosted family photo library (Google-Photos-shaped:
# phone auto-backup, timeline, albums, on-server ML for faces and search).
# Inert until a host sets `services.immich.enable`.
#
# Same reachability posture as the media stack: binds everywhere, zero open
# firewall ports, reached over the trusted tailscale0 interface (:2283).
# Remote phone backup (away from home) is deliberately unsolved for now —
# family phones on the tailnet, or a tunnel, is a later decision.
#
# STORAGE. /srv/photos — its own tree, NOT the media tree: photos are
# irreplaceable family state (and the standing trigger for the deferred
# off-host backup design), while /srv/media is redownloadable. Same RAID
# migration story: copy tree, remount, done.
#
# The NixOS module brings up PostgreSQL (with pgvector) and Redis itself;
# machine-learning defaults on — models download from Hugging Face on first
# use, which the fence's public-internet fall-through permits.
{
  flake.nixosModules.immich =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
      networkFences = import ../../lib/network-fences.nix;
    in
    {
      config = mkIf config.services.immich.enable {
        services.immich = {
          host = mkDefault "0.0.0.0";
          port = mkDefault 2283;
          openFirewall = mkDefault false; # tailnet-only
          mediaLocation = mkDefault "/srv/photos";
        };

        # Anti-pivot fence, media-stack shape: tailnet + loopback (postgres,
        # redis, ML sidecar) allowed, every private range denied, public
        # internet falls through (ML model downloads, reverse geocoding).
        # No Slice override — upstream already confines both units to its
        # own system-immich.slice.
        systemd.services.immich-server.serviceConfig = {
          IPAddressAllow = [
            "100.64.0.0/10"
            "127.0.0.0/8"
            "::1"
          ];
          IPAddressDeny = networkFences.privateRanges;
        };
        systemd.services.immich-machine-learning.serviceConfig = {
          IPAddressAllow = [
            "127.0.0.0/8"
            "::1"
          ];
          IPAddressDeny = networkFences.privateRanges;
        };
      };
    };
}
