# Immich — photo library with on-server ML, reached over tailscale0 at
# :2283 with no open firewall ports. Photos live in /srv/photos, separate
# from the media tree. ML models download from Hugging Face on first use.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.immich;
  flake.nixosModules.immich =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault;
      inherit (lib.ship) fences;
    in
    {
      config = {
        shipProxy.routes.immich = {
          port = 2283;
          # Phone backup ships originals; immich checks size itself.
          proxyExtra = ''
            client_max_body_size 0;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };

        # Upstream only auto-creates its default /var/lib location, not a
        # custom mediaLocation.
        systemd.tmpfiles.rules = [
          "d ${config.services.immich.mediaLocation} 0750 immich immich -"
        ];

        services.immich = {
          enable = true;
          # Bind wide so the tailnet reaches :2283 without the vhost.
          host = mkDefault "0.0.0.0";
          mediaLocation = mkDefault "/srv/photos";
        };

        # The internet falls through allowed, for model downloads. These
        # denies are not "any", so 127.0.0.0/8 must be named.
        systemd.services.immich-server.serviceConfig = {
          IPAddressAllow = fences.loopback ++ [ fences.tailnet ];
          IPAddressDeny = fences.privateRanges ++ [ "127.0.0.0/8" ];
        };
        systemd.services.immich-machine-learning.serviceConfig = {
          IPAddressAllow = fences.loopback;
          IPAddressDeny = fences.privateRanges ++ [ "127.0.0.0/8" ];
        };
      };
    };
}
