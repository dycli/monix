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
      # The Reolinks are unplugged for now; they come back.
      shipCameras.offline = [
        "cam1"
        "cam2"
      ];
      # Things that move all day kept the Nursery camera detecting at full
      # rate (~1.7 cores): the Tapo clock overlay and the crib mobile.
      shipCameras.motionMasks.tapo2 = [
        "0,0,0.4,0,0.4,0.06,0,0.06"
        "0.37,0,0.55,0,0.55,0.26,0.37,0.26"
      ];
      shipCameras.lanSubnets = singleton "192.168.1.0/24";

      # The Reolinks join once they are back on the wall.
      # The AirGradient ONE, on the IoT VLAN with the frame.
      services.hob.air.address = "192.168.30.191";

      hob.cameras = {
        tapo1 = "Living room";
        tapo2 = "Nursery";
      };

      services.syncthing.enable = true;

      matrix.serverName = "chat.su.is";
    };
}
