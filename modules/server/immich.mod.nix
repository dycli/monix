# Immich aspect — self-hosted family photo library (phone auto-backup,
# timeline, albums, on-server ML for faces and search). Inert until a host
# sets `services.immich.enable`.
#
# Same reachability posture as the media stack: binds everywhere, zero open
# firewall ports, reached over the trusted tailscale0 interface (:2283).
#
# STORAGE. /srv/photos — its own tree, NOT the media tree: photos are
# irreplaceable family state, while /srv/media is redownloadable.
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
        # The upstream module only auto-creates its default /var/lib
        # location; a custom mediaLocation needs this. 0750 — the tree is
        # immich's alone.
        systemd.tmpfiles.rules = [
          "d ${config.services.immich.mediaLocation} 0750 immich immich -"
        ];

        services.immich = {
          host = mkDefault "0.0.0.0";
          port = mkDefault 2283;
          openFirewall = mkDefault false; # tailnet-only
          mediaLocation = mkDefault "/srv/photos";
        };

        # Anti-pivot fence, media-stack shape: tailnet + loopback allowed,
        # every private range denied, public internet falls through (ML
        # model downloads, reverse geocoding). No Slice override — upstream
        # already confines both units to system-immich.slice. Loopback is
        # networkFences.loopback (the seat plane is outside it), and 127/8
        # must be named in the DENY too: these denies are not "any", so
        # unmatched traffic would fall through allowed.
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
