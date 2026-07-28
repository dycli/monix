# Frigate aspect — NVR with on-host object detection for the ship's
# cameras (Reolink RLC-520A PoE pair; Tapo C225s can join the same way).
# Inert until a host sets `shipCameras.enable`.
#
# go2rtc (separate unit, loopback-only) connects to each camera once and
# restreams; Frigate consumes the restreams: full-res stream is recorded,
# the small sub-stream feeds detection. Detection runs on CPU (two
# cameras is light); VAAPI handles decode. Recordings live in
# /var/lib/frigate (StateDirectory) — camera footage is transient bulk,
# not the precious tier.
#
# The web UI rides the ship proxy: the upstream module creates the nginx
# vhost for `hostname`, we layer the wildcard cert on it. Frigate + go2rtc
# are fenced to LAN (cameras) + loopback — an NVR needs zero internet.
#
# Camera credentials come from envFile (agenix): FRIGATE_RTSP_PASSWORD=...
# — one `frigate` account with the same password on every camera (Reolink
# users and Tapo "camera accounts" alike). go2rtc expands ${VARS};
# Frigate expands {FRIGATE_*}.
{
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

      networkFences = import ../../lib/network-fences.nix;
      cfg = config.shipCameras;

      lanFence = {
        Slice = "services.slice";
        IPAddressAllow = [
          "127.0.0.0/8"
          "::1"
        ]
        ++ cfg.lanSubnets;
        IPAddressDeny = networkFences.privateRanges ++ [ "any" ];
      };

      # Shared by go2rtc (which does the connecting; ''${VAR} env syntax)
      # and Frigate's own config (which only needs to know the restreams
      # exist so its UI offers MSE/WebRTC; {VAR} env syntax).
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

      # One Frigate camera definition per entry: record the go2rtc main
      # restream, detect on the sub restream.
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

        # --- go2rtc: one connection per camera, restreamed on loopback ---
        services.go2rtc = {
          enable = true;
          settings = {
            # origin "*": HA's dashboard reaches these websockets through
            # its own proxy, so the browser Origin (ha.<domain>) never
            # matches go2rtc's host and is rejected without this.
            api = {
              listen = "127.0.0.1:1984";
              origin = "*";
            };
            rtsp.listen = "127.0.0.1:8554";
            # WebRTC negotiates directly between browser and go2rtc (it
            # can't ride the nginx proxy) — bind wide, reachability is the
            # firewall's job.
            webrtc.listen = ":8555";
            streams = streamsWith "\${FRIGATE_RTSP_PASSWORD}";
          };
        };
        systemd.services.go2rtc.serviceConfig = lanFence // {
          EnvironmentFile = cfg.envFile;
          # …plus the tailnet: browsers negotiate WebRTC with go2rtc
          # directly (:8555), unlike everything else which rides nginx.
          IPAddressAllow = lanFence.IPAddressAllow ++ [ "100.64.0.0/10" ];
        };

        # --- Frigate ---
        services.frigate = {
          enable = true;
          hostname = "frigate.${config.shipProxy.domain}";
          vaapiDriver = "radeonsi";

          # The build-time validator can't expand {FRIGATE_*} env
          # references (the onvif password) — secrets only exist at
          # runtime. Config errors surface in the unit log instead.
          checkConfig = false;

          settings = {
            # See streamsWith: frigate must know the external go2rtc's
            # streams or its UI never offers MSE/WebRTC (endless spinner
            # on fullscreen).
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
              # C225 sub-stream is 640x360; pan/tilt via ONVIF (port 2020),
              # same frigate account.
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
          # Frigate assumes this cache subdir exists (container tmpfs
          # provides it); without it review previews fail to render.
          CacheDirectory = [ "frigate/preview_frames" ];
        };

        # Wildcard cert + TLS on the vhost the upstream module created.
        services.nginx.virtualHosts.${config.services.frigate.hostname} = {
          useACMEHost = config.shipProxy.domain;
          forceSSL = true;
        };

        # --- MQTT broker (loopback-only) for Frigate→HA events ---
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
          Slice = "services.slice";
          IPAddressAllow = [
            "127.0.0.0/8"
            "::1"
          ];
          IPAddressDeny = "any";
        };
      };
    };
}
