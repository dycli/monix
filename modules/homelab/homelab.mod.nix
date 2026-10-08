# The lab bundle: the house's services — media automation, family apps,
# smart home, their shared front door and alerting — plus the agent lab
# (AI seat, worker fleet, inference; wired in ai/).
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

      homeAssistant.lanSubnets = singleton "192.168.1.0/24";

      shipCameras.reolink = {
        cam1 = "192.168.1.201";
        cam2 = "192.168.1.55";
      };
      shipCameras.tapo = {
        tapo1 = "192.168.1.218";
        tapo2 = "192.168.1.220";
      };
      shipCameras.lanSubnets = singleton "192.168.1.0/24";

      shipProxy.dashboardHost = "hp.su.is";

      services.syncthing.enable = true;

      matrix.serverName = "chat.su.is";

      agentFleet.workers = [
        "astrapia"
        "cicinnurus"
      ];
      fleetLogStream.inviteUsers = singleton "@dylan:chat.su.is";

      sokka.users = singleton "@dylan:chat.su.is";
      alerts.summary.model = "qwen3.8-27b-q4-k-m";
    };
}
