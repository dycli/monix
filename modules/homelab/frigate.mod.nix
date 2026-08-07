# NVR with on-host object detection for Reolink and Tapo cameras.
#
# go2rtc connects to each camera once and restreams on loopback; Frigate
# records the full-res stream and detects on the sub-stream, on CPU with
# VAAPI decode. Recordings live in /var/lib/frigate.
#
# Both units are fenced to the camera LAN and loopback; an NVR needs no
# internet. The upstream module creates the nginx vhost, which gets the
# wildcard cert layered on below.
#
# One `frigate` camera account, its password from envFile. go2rtc expands
# ${VARS} while Frigate expands {FRIGATE_*}.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.frigate;
  flake.nixosModules.frigate =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) concatMapAttrs mapAttrs;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;

      inherit (lib.ship) fences;
      cfg = config.shipCameras;

      lanFence = {
        IPAddressAllow = fences.loopback ++ cfg.lanSubnets;
        IPAddressDeny = fences.privateRanges ++ [ "any" ];
      };

      # Shared by go2rtc, which connects, and by Frigate, which only needs
      # to know the restreams exist. Note the differing env syntax.
      streamsWith =
        pass:
        concatMapAttrs (name: ip: {
          ${name} = [ "rtsp://frigate:${pass}@${ip}:554/h264Preview_01_main" ];
          "${name}_sub" = [ "rtsp://frigate:${pass}@${ip}:554/h264Preview_01_sub" ];
        }) cfg.reolink
        // concatMapAttrs (name: ip: {
          ${name} = [ "rtsp://frigate:${pass}@${ip}:554/stream1" ];
          "${name}_sub" = [ "rtsp://frigate:${pass}@${ip}:554/stream2" ];
        }) cfg.tapo;

      # Record the main restream, detect on the sub restream.
      frigateCamera = detect: name: _: {
        ffmpeg.inputs = [
          {
            path = "rtsp://127.0.0.1:8554/${name}";
            input_args = "preset-rtsp-restream";
            roles = [ "record" ];
          }
          {
            path = "rtsp://127.0.0.1:8554/${name}_sub";
            input_args = "preset-rtsp-restream";
            roles = [ "detect" ];
          }
        ];
        inherit detect;
      };
    in
    {
      options.shipCameras = {
        enable = mkEnableOption "Frigate NVR for the ship's cameras";

        reolink = mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = {
            front = "192.168.1.201";
          };
          description = "Reolink cameras (RLC-520A pattern): name → IP.";
        };

        tapo = mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Tapo cameras (C225 pattern): name → IP.";
        };

        lanSubnets = mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "192.168.1.0/24" ];
          description = "Subnets the cameras live on.";
        };

        envFile = mkOption {
          type = lib.types.str;
          description = "agenix env file with the FRIGATE_* camera credentials.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = config.shipProxy.enable;
            message = "shipCameras needs shipProxy (frigate.<domain> vhost + cert)";
          }
        ];

        services.go2rtc = {
          enable = true;
          settings = {
            # HA's dashboard proxies these websockets, so the browser
            # Origin never matches go2rtc's host and is rejected without
            # this.
            api = {
              listen = "127.0.0.1:1984";
              origin = "*";
            };
            rtsp.listen = "127.0.0.1:8554";
            # WebRTC negotiates browser-to-go2rtc directly and cannot ride
            # the nginx proxy; the firewall handles reachability.
            webrtc.listen = ":8555";
            streams = streamsWith "\${FRIGATE_RTSP_PASSWORD}";
          };
        };
        systemd.services.go2rtc.serviceConfig = lanFence // {
          EnvironmentFile = cfg.envFile;
          # Plus the tailnet, for the direct WebRTC negotiation above.
          IPAddressAllow = lanFence.IPAddressAllow ++ [ "100.64.0.0/10" ];
        };

        services.frigate = {
          enable = true;
          hostname = "frigate.${config.shipProxy.domain}";
          vaapiDriver = "radeonsi";

          # The build-time validator cannot expand {FRIGATE_*}, since
          # those secrets exist only at runtime; config errors surface in
          # the unit log instead.
          checkConfig = false;

          settings = {
            # TEMPORARY — REMOVE after one switch: the original admin
            # password print has rotated out of the journal. On restart
            # Frigate regenerates it and logs the new one; while this is
            # set, every restart resets it again.
            auth.reset_admin_password = true;

            # Frigate must know the external go2rtc's streams or its UI
            # never offers MSE/WebRTC and spins on fullscreen.
            go2rtc.streams = streamsWith "{FRIGATE_RTSP_PASSWORD}";

            mqtt = {
              enabled = true;
              host = "127.0.0.1";
            };

            ffmpeg.hwaccel_args = "preset-vaapi";

            detectors.cpu1 = {
              type = "cpu";
              num_threads = 4;
            };

            objects.track = [
              "person"
              "car"
              "dog"
              "cat"
            ];

            record = {
              enabled = true;
              retain = {
                days = 7;
                mode = "motion";
              };
              alerts.retain.days = 14;
              detections.retain.days = 14;
            };
            snapshots.enabled = true;

            cameras =
              # RLC-520A sub-stream is 640x480.
              mapAttrs (frigateCamera {
                enabled = true;
                width = 640;
                height = 480;
              }) cfg.reolink
              # C225 sub-stream is 640x360; pan/tilt over ONVIF on 2020.
              // mapAttrs (
                name: ip:
                frigateCamera {
                  enabled = true;
                  width = 640;
                  height = 360;
                } name ip
                // {
                  onvif = {
                    host = ip;
                    port = 2020;
                    user = "frigate";
                    password = "{FRIGATE_RTSP_PASSWORD}";
                  };
                }
              ) cfg.tapo;
          };
        };
        systemd.services.frigate.serviceConfig = lanFence // {
          EnvironmentFile = cfg.envFile;
          # Frigate assumes this cache subdirectory exists, as its
          # container tmpfs provides; review previews fail without it.
          CacheDirectory = [ "frigate/preview_frames" ];
        };

        # TLS on the vhost the upstream module created.
        services.nginx.virtualHosts.${config.services.frigate.hostname} = {
          useACMEHost = config.shipProxy.domain;
          forceSSL = true;
        };

        # Loopback MQTT broker carrying Frigate events to Home Assistant.
        services.mosquitto = {
          enable = true;
          listeners = [
            {
              address = "127.0.0.1";
              port = 1883;
              settings.allow_anonymous = true;
              acl = [ "topic readwrite #" ];
            }
          ];
        };
        systemd.services.mosquitto.serviceConfig = {
          IPAddressAllow = fences.loopback;
          IPAddressDeny = "any";
        };
      };
    };
}
