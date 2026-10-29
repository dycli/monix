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
          route = "si";
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

      yeoman.instances = {
        sokka = {
          person = "Dylan";
          users = singleton "@dylan:chat.su.is";
          alerts = true;
          computer = true;
          voice = "rex";
          newsKeyFile = "/var/lib/news-keys/sokka";
        };
        suki = {
          person = "Gab";
          users = singleton "@gab:chat.su.is";
          style = "Gab likes a slightly warmer tone.";
          computer = true;
          voice = "ara";
        };
        # Bridge itself in the web chat, beside paseo
        # (/var/lib/bridge/raava.md).
        raava = {
          name = "Bridge";
          person = "Dylan";
          # Sokka is Dylan's door: a message to Dylan goes there.
          door = false;
          seat = true;
          web = true;
          voice = "eve";
          models = [
            "opus"
            "sonnet"
            "haiku"
            "fable"
          ];
          efforts = [
            "low"
            "medium"
            "high"
            "xhigh"
            "max"
          ];
        };
        # One-off questions: no Matrix, and each message forgotten an hour
        # after it was said, unless the page sets another window.
        amnesia = {
          person = "Dylan";
          # Sokka is Dylan's door: a message to Dylan goes there.
          door = false;
          web = true;
          forgetAfter = 60;
          models = [
            "opus"
            "sonnet"
            "haiku"
            "fable"
          ];
          efforts = [
            "low"
            "medium"
            "high"
            "xhigh"
            "max"
          ];
        };
        # Libri, the product grown from yeoman and hippo (~bridge/ark/libri),
        # run from the seat's latest build of it as the seat itself: Bridge
        # with the seat's tools and memory, Dylan's daily chat
        # (/var/lib/bridge/harness.md).
        libri = {
          name = "Bridge";
          person = "Dylan";
          seat = true;
          # Sokka is Dylan's door: a message to Dylan goes there.
          door = false;
          web = true;
          build = "/var/lib/libri-build/current";
          # The server's name for the app at libri.su.is; libri.su.is
          # itself still reaches the chat until the app stands apart.
          aliases = [ "si" ];
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
        azula = {
          person = "Dylan";
          # Sokka is Dylan's door: a message to Dylan goes there.
          door = false;
          users = singleton "@dylan:chat.su.is";
          localModel = "qwen3.8-27b-uncensored-q4-k-m";
          style = "You are Azula: sharp, imperious and unfiltered. Say what you think without hedging or moralizing.";
        };
      };

      news.apiKeys = singleton "sokka";

    };
}
