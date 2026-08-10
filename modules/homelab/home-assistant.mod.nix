# Smart-home backend, tailnet-only on :8123 behind ha.<domain>.
# Integration wiring is .storage state; Nix owns the service, its
# components and its reachability. The fence allows the configured LAN
# subnets; the fleet bridge and every other private range stay denied.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.home-assistant;
  flake.nixosModules.home-assistant =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.ship) fences;
      cfg = config.homeAssistant;
    in
    {
      options.homeAssistant.lanSubnets = lib.options.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "192.168.1.0/24" ];
        description = "Home LAN subnets HA may reach (IoT devices, discovery).";
      };

      config = mkIf config.services.home-assistant.enable {
        services.home-assistant = {
          openFirewall = false; # tailnet-only (UI/API on :8123)

          # Tapo C225 1.x firmware rejects plain-RSA key exchange and
          # python-kasa <= 0.10.2 offers only RSA-kx ciphers, so the TLS
          # handshake fails. Drop once the nixpkgs pin carries ECDHE.
          package = pkgs.home-assistant.override {
            packageOverrides = _: prev: {
              python-kasa = prev.python-kasa.overridePythonAttrs (old: {
                postPatch = (old.postPatch or "") + ''
                  substituteInPlace kasa/transports/sslaestransport.py \
                    --replace-fail '"AES256-GCM-SHA384",' '"ECDHE-RSA-AES128-GCM-SHA256", "AES256-GCM-SHA384",'
                '';
              });
            };
          };

          extraComponents = [
            "met"
            "backup"
            "airgradient"
          ]
          # Frigate events arrive over MQTT; tplink drives the Tapo cameras
          # directly with the same camera account Frigate's RTSP uses.
          ++ lib.lists.optionals config.shipCameras.enable [
            "mqtt"
            "tplink"
          ];

          # UI setup points this at http://127.0.0.1:5000.
          customComponents = lib.lists.optional config.shipCameras.enable pkgs.home-assistant-custom-components.frigate;

          customLovelaceModules = lib.lists.optional config.shipCameras.enable pkgs.home-assistant-custom-lovelace-modules.advanced-camera-card;

          config = {
            # The standard integration bundle.
            default_config = { };

            homeassistant = {
              name = "Home";
              unit_system = "us_customary";
              time_zone = config.time.timeZone;
            };

            # Trust loopback's X-Forwarded-For across the nginx hop.
            http = {
              use_x_forwarded_for = true;
              trusted_proxies = [
                "127.0.0.1"
                "::1"
              ];
            };
          };
        };

        systemd.services.home-assistant.serviceConfig = {
          IPAddressAllow = fences.loopback ++ [ "100.64.0.0/10" ] ++ cfg.lanSubnets;
          IPAddressDeny = fences.privateRanges;
        };
      };
    };
}
