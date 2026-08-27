# The lab bundle: the house's services — media automation, family apps,
# smart home, their shared front door and alerting — plus the agent lab
# (cockpit seat, worker fleet, inference; wired in ai/).
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

      # Resolve via the router rather than the tailnet's global
      # nameservers, so the role does not inherit the ad-block resolver's
      # outages or false positives. Merges with the aspect's --ssh.
      services.tailscale.extraSetFlags = singleton "--accept-dns=false";

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

      remy.inviteUsers = [
        "@dylan:chat.su.is"
        "@gab:chat.su.is"
      ];
      remy.scratchpad.users = singleton "@dylan:chat.su.is";
      remy.model = "qwen3.6-35b-a3b";
      remy.famlog.path = "/home/${config.primaryUser}/crate/sync/notes/famlog.md";
      remy.famlog.owner = config.primaryUser;
      remy.famlog.group = "syncthing";
    };
}
