[
  {
    path = "/srv/media";
    directory = "media";
    services = [
      "jellyfin"
      "sonarr"
      "radarr"
      "bazarr"
      "sabnzbd"
      "calibre-web"
    ];
  }
  {
    path = "/srv/photos";
    directory = "photos";
    services = [
      "immich-server"
      "immich-machine-learning"
    ];
  }
  {
    path = "/var/lib/frigate";
    directory = "cameras";
    services = [ "frigate" ];
  }
  {
    path = "/var/lib/jellyfin";
    directory = "services/jellyfin";
    services = [ "jellyfin" ];
  }
  {
    path = "/var/lib/sonarr";
    directory = "services/sonarr";
    services = [ "sonarr" ];
  }
  {
    path = "/var/lib/radarr";
    directory = "services/radarr";
    services = [ "radarr" ];
  }
  {
    path = "/var/lib/bazarr";
    directory = "services/bazarr";
    services = [ "bazarr" ];
  }
  {
    path = "/var/lib/sabnzbd";
    directory = "services/sabnzbd";
    services = [ "sabnzbd" ];
  }
  {
    path = "/var/lib/calibre-web";
    directory = "services/calibre-web";
    services = [ "calibre-web" ];
  }
]
