# NVR with on-host object detection for Reolink and Tapo cameras. go2rtc
# connects to each camera once and restreams on loopback; Frigate records
# the full-res stream and detects on the sub-stream.
#
# One `frigate` camera account, its password from envFile. go2rtc expands
# ${VARS} while Frigate expands {FRIGATE_*}.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.frigate;
  flake.nixosModules.frigate =
    {
      config,
      lib,
      ...
    }:
    let
      inherit (lib.attrsets) concatMapAttrs mapAttrs;
      inherit (lib.lists) singleton;
      inherit (lib.options) mkOption;

      inherit (lib.ship) fences;
      cfg = config.shipCameras;

      lanFence = {
        IPAddressAllow = fences.loopback ++ cfg.lanSubnets;
        IPAddressDeny = "any";
      };

      # go2rtc connects; Frigate only needs to know the restreams exist.
      streamsWith =
        pass:
        (
          cfg.reolink
          |> concatMapAttrs (
            name: ip: {
              ${name} = singleton "rtsp://frigate:${pass}@${ip}:554/h264Preview_01_main";
              "${name}_sub" = singleton "rtsp://frigate:${pass}@${ip}:554/h264Preview_01_sub";
            }
          )
        )
        // (
          cfg.tapo
          |> concatMapAttrs (
            name: ip: {
              ${name} = singleton "rtsp://frigate:${pass}@${ip}:554/stream1";
              "${name}_sub" = singleton "rtsp://frigate:${pass}@${ip}:554/stream2";
            }
          )
        );

      frigateCamera = detect: name: _: {
        ffmpeg.inputs = [
          {
            path = "rtsp://127.0.0.1:8554/${name}";
            input_args = "preset-rtsp-restream";
            roles = singleton "record";
          }
          {
            path = "rtsp://127.0.0.1:8554/${name}_sub";
            input_args = "preset-rtsp-restream";
            roles = singleton "detect";
          }
        ];
        inherit detect;
      };
    in
    {
      options.shipCameras = {
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
          example = singleton "192.168.1.0/24";
          description = "Subnets the cameras live on.";
        };

        envFile = mkOption {
          type = lib.types.str;
          description = "agenix env file with the FRIGATE_* camera credentials.";
        };
      };

      config = {
        services.go2rtc = {
          enable = true;
          settings = {
            # go2rtc offers only same-origin or "*", and proxied
            # websockets arrive with a browser Origin that cannot match
            # this host. The fence is elsewhere: the listen is
            # loopback-only, and both routes to it — HA's server-side
            # proxy and Frigate's auth_request vhost — authenticate
            # before go2rtc sees a frame.
            api = {
              listen = "127.0.0.1:1984";
              origin = "*";
            };
            rtsp.listen = "127.0.0.1:8554";
            # WebRTC negotiates browser-to-go2rtc and cannot ride nginx.
            webrtc.listen = ":8555";
            streams = streamsWith "\${FRIGATE_RTSP_PASSWORD}";
          };
        };
        systemd.services.go2rtc.serviceConfig = lanFence // {
          EnvironmentFile = cfg.envFile;
          # Plus the tailnet, for the direct WebRTC negotiation.
          IPAddressAllow = lanFence.IPAddressAllow ++ singleton fences.tailnet;
        };

        services.frigate = {
          enable = true;
          hostname = "frigate.${config.shipProxy.domain}";
          vaapiDriver = "radeonsi";

          # The build-time validator cannot expand {FRIGATE_*}; config
          # errors surface in the unit log instead.
          checkConfig = false;

          settings = {
            # Frigate must know the external go2rtc's streams or its UI
            # never offers MSE/WebRTC.
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
              (
                cfg.reolink
                |> mapAttrs (frigateCamera {
                  enabled = true;
                  width = 640;
                  height = 480;
                })
              )
              # C225 sub-stream is 640x360; pan/tilt over ONVIF on 2020.
              // (
                cfg.tapo
                |> mapAttrs (
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
                )
              );
          };
        };
        systemd.services.frigate.serviceConfig = lanFence // {
          EnvironmentFile = cfg.envFile;
          # Frigate assumes this cache subdirectory exists, as its upstream
          # container tmpfs provides; review previews fail without it.
          CacheDirectory = singleton "frigate/preview_frames";
        };

        services.nginx.virtualHosts.${config.services.frigate.hostname} = {
          useACMEHost = config.shipProxy.domain;
          forceSSL = true;
        };

        # Carries Frigate events to Home Assistant.
        services.mosquitto = {
          enable = true;
          listeners = singleton {
            address = "127.0.0.1";
            port = 1883;
            settings.allow_anonymous = true;
            acl = singleton "topic readwrite #";
          };
        };
        systemd.services.mosquitto.serviceConfig = {
          IPAddressAllow = fences.loopback;
          IPAddressDeny = "any";
        };
      };
    };
}
