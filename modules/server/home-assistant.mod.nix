# Home Assistant aspect — smart-home backend (thermostat, sensors, Frigate
# cameras). Inert until a host sets `services.home-assistant.enable`.
#
# Tailnet-only on :8123, pretty name via the ship proxy (ha.<domain>).
# Integration wiring (OAuth, device pairing) is web-UI/.storage state like
# the *arrs — Nix owns the service, components, and reachability only.
#
# FENCE EXCEPTION: HA's job is talking to the home LAN (thermostats,
# cameras, mDNS discovery), so configured LAN subnets are allowed alongside
# tailnet + loopback; the fleet bridge and every other private range stay
# denied.
{
  flake.nixosModules.home-assistant =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      networkFences = import ../../lib/network-fences.nix;
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

          # Current Tapo camera firmware (C225 1.x, 2026) rejects plain-RSA
          # key exchange; python-kasa <=0.10.2 offers only RSA-kx ciphers so
          # the TLS handshake fails. Upstream added ECDHE after 0.10.2 —
          # drop this override once the nixpkgs pin carries it.
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
            # Sane onboarding baseline (weather, radio browser, backups).
            "met"
            "radio_browser"
            "backup"
          ]
          # Camera-stack integrations: Frigate events arrive over MQTT, and
          # tplink talks to the Tapo cams directly (privacy mode, LED, ...)
          # using the same in-app "camera account" Frigate's RTSP uses.
          ++ lib.lists.optionals config.shipCameras.enable [
            "mqtt"
            "tplink"
          ];

          # The Frigate integration is a custom component (HACS-land
          # upstream, packaged in nixpkgs). UI setup: point it at
          # http://127.0.0.1:5000 (frigate's local port).
          customComponents = lib.lists.optional config.shipCameras.enable (
            pkgs.home-assistant-custom-components.frigate
          );

          # Advanced Camera Card (né frigate-hass-card): live WebRTC, PTZ,
          # and clip/event browsing as a dashboard card.
          customLovelaceModules = lib.lists.optional config.shipCameras.enable (
            pkgs.home-assistant-custom-lovelace-modules.advanced-camera-card
          );

          config = {
            # default_config = the standard integration bundle (automations,
            # mobile app API, history, mDNS discovery, ...).
            default_config = { };

            homeassistant = {
              name = "Home";
              unit_system = "us_customary";
              time_zone = "America/New_York";
            };

            # Behind the ship proxy: trust loopback's X-Forwarded-For so
            # client IPs (and HA's own rate limiting) work through nginx.
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
          Slice = "services.slice";
          IPAddressAllow = [
            "100.64.0.0/10"
            "127.0.0.0/8"
            "::1"
          ]
          ++ cfg.lanSubnets;
          IPAddressDeny = networkFences.privateRanges;
        };
      };
    };
}
