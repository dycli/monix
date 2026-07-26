# Home Assistant aspect — the smart-home backend (thermostat, sensors,
# eventually Frigate cameras). Inert until a host sets
# `services.home-assistant.enable`.
#
# Reachability: tailnet-only on :8123, pretty name via the ship proxy
# (ha.<domain>). Integration wiring (Nest OAuth, device pairing) is
# web-UI/.storage state like the *arrs — Nix owns the service, components,
# and reachability; the UI owns which devices exist.
#
# FENCE EXCEPTION. Unlike the media stack, HA's *job* is talking to the
# home LAN (thermostats, cameras, mDNS discovery), so the configured LAN
# subnets are allowed alongside tailnet + loopback. The fleet bridge and
# every other private range stay denied; public internet falls through
# (Nest is a cloud integration until the thermostat is replaced with
# something local-first).
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

          extraComponents = [
            # Sane onboarding baseline (weather, radio browser, backups).
            "met"
            "radio_browser"
            "backup"
            # The captain's thermostat (cloud; Google Device Access setup
            # happens in the UI when he gets to it).
            "nest"
            # ESPHome ready for future local-first sensors/devices.
            "esphome"
          ]
          # Frigate events arrive over MQTT when the NVR is up.
          ++ lib.lists.optional config.shipCameras.enable "mqtt";

          # The Frigate integration is a custom component (HACS-land
          # upstream, packaged in nixpkgs). UI setup: point it at
          # http://127.0.0.1:5000 (frigate's unauthenticated local port).
          customComponents = lib.lists.optional config.shipCameras.enable (
            pkgs.home-assistant-custom-components.frigate
          );

          # The Advanced Camera Card (né frigate-hass-card): live WebRTC,
          # PTZ, and clip/event browsing as a dashboard card — the piece
          # that makes HA a first-class camera surface instead of
          # stills-with-a-tap-through.
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
