# Syncthing for the primary user. Device IDs are public keys, not secrets,
# and are declared here with the one shared folder so every host agrees on
# the mesh; a host that enables syncthing joins automatically at
# ~/crate/sync.
#
# overrideDevices and overrideFolders default true upstream, so peers or
# folders added through the web UI are removed on the next switch. GUI
# credentials and the API key stay runtime state.
{
  flake.nixosModules.syncthing =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
    in
    {
      config = mkIf config.services.syncthing.enable {
        services.syncthing = {
          user = mkDefault config.primaryUser;
          dataDir = mkDefault "/home/${config.primaryUser}";
          configDir = mkDefault "/home/${config.primaryUser}/.config/syncthing";
          # Every peer is a tailnet device and tailscale0 already passes
          # the sync and discovery ports, so no global opening is needed.
          # Peers find the tailnet addresses through global discovery.
          openDefaultPorts = false;
          settings.devices = {
            fw3.id = "G2BLKW7-HEC7IY3-F2NUM4K-4AH57JV-JVJ4SJZ-HHOLW7F-DQEGXGU-2OVC5Q2";
            fw0.id = "35P3LQK-ULGW6UH-SJPXDGG-KY6XBM3-OAHST4N-JTVUEAB-5HU53P2-P2RAUAP";
            # Phone. Its own side is configured on-device, not by the flake.
            px1.id = "76LMPA6-QYQ7PFY-PG7YCZD-GTWX3VO-VXD46RW-SU72IWR-FEATUJX-KNIE2AF";
          };
          settings.folders."zahzi-nepxh" = {
            label = "sync";
            path = "/home/${config.primaryUser}/crate/sync";
            devices = [
              "fw3"
              "fw0"
              "px1"
            ];
          };
        };
      };
    };
}
