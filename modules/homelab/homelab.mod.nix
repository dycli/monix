# The homelab bundle: the house's services — media automation, family
# apps, smart home, their shared front door and alerting.
#
# Only role wiring lives here. agenix ciphertext is encrypted to one
# host's key and cannot travel, so every `*File` option, along with
# hardware facts, is set by the importing host.
{
  flake.nixosModules.homelab =
    { config, lib, ... }:
    {
      # sshd stays reachable over the tailnet, whose interface is trusted;
      # port 22 never opens publicly.
      services.openssh.openFirewall = lib.modules.mkDefault false;

      # Resolve via the router rather than the tailnet's global
      # nameservers, so the role does not inherit the ad-block resolver's
      # outages or false positives. Merges with the aspect's --ssh.
      services.tailscale.extraSetFlags = [ "--accept-dns=false" ];

      alerts.enable = true;
      alerts.summary.enable = true;

      minecraft.enable = true;

      media.enable = true;

      services.home-assistant.enable = true;
      homeAssistant.lanSubnets = [ "192.168.1.0/24" ];

      shipCameras.enable = true;
      shipCameras.reolink = {
        cam1 = "192.168.1.201";
        cam2 = "192.168.1.55";
      };
      shipCameras.tapo = {
        tapo1 = "192.168.1.218";
        tapo2 = "192.168.1.220";
      };
      shipCameras.lanSubnets = [ "192.168.1.0/24" ];

      services.immich.enable = true;

      shipProxy.enable = true;
      shipProxy.dashboardHost = "hp.su.is";

      services.homepage-dashboard.enable = true;

      services.syncthing.enable = true;

      matrix.enable = true;
      matrix.serverName = "chat.su.is";

      remy.enable = true;
      remy.inviteUsers = [
        "@dylan:chat.su.is"
        "@gab:chat.su.is"
      ];
      remy.scratchpad.users = [ "@dylan:chat.su.is" ];
      remy.model = "qwen3.6-35b-a3b";
      remy.famlog.path = "/home/${config.primaryUser}/crate/sync/notes/famlog.md";
      remy.famlog.owner = config.primaryUser;
      remy.famlog.group = "syncthing";

      curtisbot.enable = true;
      curtisbot.guildId = "916523305362685952";
      curtisbot.testGuildId = "1529484237210910753";
    };
}
