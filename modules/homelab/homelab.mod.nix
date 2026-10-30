# The lab bundle: the house's services — media automation, family apps,
# smart home, their shared front door and alerting — plus the agent lab
# (AI seat, household assistants, inference; wired in ai/).
#
# Only role wiring lives here. agenix ciphertext is encrypted to one
# host's key and cannot travel, so every `*File` option, along with
# hardware facts, is set by the importing host.
{
  flake.nixosModules.lab =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
    in
    {
      # sshd stays reachable over the tailnet, whose interface is trusted;
      # port 22 never opens publicly.
      services.openssh.openFirewall = lib.modules.mkDefault false;

      # Use MagicDNS names and the tailnet's filtering resolver.
      services.tailscale.extraSetFlags = singleton "--accept-dns=true";

      # 192.168.30.0/24 is the IoT VLAN (frame, AirGradient).
      homeAssistant.lanSubnets = [
        "192.168.1.0/24"
        "192.168.30.0/24"
      ];

      shipCameras.reolink = {
        cam1 = "192.168.1.201";
        cam2 = "192.168.1.55";
      };
      shipCameras.tapo = {
        tapo1 = "192.168.1.218";
        tapo2 = "192.168.1.220";
      };
      shipCameras.lanSubnets = singleton "192.168.1.0/24";

      # The Reolinks join once they are back on the wall.
      # The AirGradient ONE, on the IoT VLAN with the frame.
      frame.air = "192.168.30.191";

      frame.cameras = {
        tapo1 = "Living room";
        tapo2 = "Nursery";
      };

      # The homepage at home.su.is: services in the order it lists them.
      frame.services = [
        {
          name = "Jellyfin";
          about = "Movies & TV";
          icon = "jellyfin";
          route = "fin";
        }
        {
          name = "Seerr";
          about = "Requests";
          icon = "jellyseerr";
          route = "q";
        }
        {
          name = "Immich";
          about = "Photos";
          icon = "immich";
          route = "pix";
        }
        {
          name = "Home Assistant";
          about = "Smart home";
          icon = "home-assistant";
          route = "ha";
        }
        {
          name = "Frigate";
          about = "Cameras";
          icon = "frigate";
          url = "https://frigate.su.is";
          check = "http://127.0.0.1:5000/api/version";
        }
        {
          name = "Calibre-Web";
          about = "eBooks";
          icon = "calibre-web";
          route = "calibre";
        }
        {
          name = "Bridge";
          about = "Dylan's assistant";
          icon = "";
          route = "libri";
          agent = true;
        }
        {
          name = "Suki";
          about = "Gab's assistant";
          icon = "";
          route = "suki";
          agent = true;
        }
        {
          name = "Paseo";
          about = "Coding agents";
          icon = "";
          check = "http://127.0.0.1:6768/";
          agent = true;
        }
        {
          name = "Endgrain";
          about = "Staff schedule";
          icon = "";
          route = "endgrain";
        }
        {
          name = "News";
          about = "Feeds and newsletters";
          icon = "miniflux";
          route = "news";
        }
        {
          name = "Money";
          about = "Spending and savings";
          icon = "";
          route = "money";
        }
        {
          name = "Frame";
          about = "Wall frame";
          icon = "";
          route = "frame";
        }
        {
          name = "Sonarr";
          about = "TV";
          icon = "sonarr";
          route = "sonarr";
        }
        {
          name = "Radarr";
          about = "Movies";
          icon = "radarr";
          route = "radarr";
        }
        {
          name = "Prowlarr";
          about = "Indexers";
          icon = "prowlarr";
          route = "prowlarr";
        }
        {
          name = "Bazarr";
          about = "Subtitles";
          icon = "bazarr";
          route = "bazarr";
        }
        {
          name = "SABnzbd";
          about = "Downloads";
          icon = "sabnzbd";
          route = "sab";
        }
      ];
      frame.disks = [
        {
          label = "System";
          path = "/";
        }
        {
          label = "Storage";
          path = "/srv/storage";
        }
        {
          label = "Backup";
          path = "/srv/backup";
        }
      ];

      services.syncthing.enable = true;

      matrix.serverName = "chat.su.is";

      # The Libri app on its own, as Paseo's app stands apart from its
      # daemons: it opens empty, and Settings adds each server by address
      # (si.su.is, suki.su.is). Served from the seat's latest build.
      shipProxy.routes.libri-app = {
        subdomain = "libri";
        root = "${lib.ship.topology.seat.libriBuild}/site";
      };

      # The Android app's newest signed build, at the fixed address
      # Obtainium polls for updates: libri.su.is/android/libri.apk. The
      # seat copies each build here; the signing key stays in its home.
      systemd.tmpfiles.settings.libri-android."/var/lib/libri-android".d = {
        user = lib.ship.topology.seat.user;
        group = "nginx";
        mode = "2750";
      };
      services.nginx.virtualHosts."libri.${config.shipProxy.domain}".locations."/android/" = {
        alias = "/var/lib/libri-android/";
        extraConfig = ''
          types { application/vnd.android.package-archive apk; }
        '';
      };

      yeoman.instances = {
        suki = {
          person = "Gab";
          style = "Gab likes a slightly warmer tone.";
          computer = true;
          voice = "ara";
        };
        # Libri, the product grown from yeoman and hippo (~bridge/ark/libri),
        # run from the seat's latest build of it as the seat itself: Bridge
        # with the seat's tools and memory, Dylan's daily chat
        # (/var/lib/bridge/harness.md).
        libri = {
          name = "Bridge";
          person = "Dylan";
          seat = true;
          web = true;
          build = lib.ship.topology.seat.libriBuild;
          # The server at si.su.is; the app at libri.su.is talks to it,
          # with no sign-in on the tailnet.
          subdomain = "si";
          open = true;
          origins = [ "https://libri.su.is" ];
          providerKeys = true;
          # Full ids, so the picker can show each model's version.
          models = [
            "claude-opus-5-5"
            "claude-sonnet-5-5"
            "claude-haiku-5-5"
            "claude-fable-5-1"
          ];
          efforts = [
            "low"
            "medium"
            "high"
            "xhigh"
            "max"
          ];
        };
      };

    };
}
