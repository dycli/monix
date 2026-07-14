# Syncthing for the primary user. Inert until a host sets
# `services.syncthing.enable = true`.
#
# The device registry (every syncthing peer and its ID — public keys, not
# secrets) and the one shared folder are declared here so all hosts agree
# on the mesh. The folder path is ~/crate/sync of the host's primary user
# on every member — a new host that enables syncthing joins the folder
# automatically. overrideDevices/overrideFolders default to true in the
# upstream module, so the flake is the source of truth: peers or folders
# added through the web UI are removed on the next switch. GUI credentials
# and the API key stay runtime state.
#
# Transcribed 2026-07-14 from the runtime configs after the fw0<->fw3
# pairing was set up and verified through the UI (work-backwards step).
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
          openDefaultPorts = true;
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
