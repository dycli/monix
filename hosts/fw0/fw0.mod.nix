# fw0 — Framework Desktop (Strix Halo, 128GB unified LPDDR5X), headless
# always-on AI server. Roles: agent-fleet microVM host, cockpit session,
# local inference. All admin/service access is tailnet-only — zero inbound
# ports on the home IP.
#
# BIOS (one-time, manual): enable AMD SVM and "restore on AC power loss" so
# the host auto-boots after an outage.
{
  self,
  inputs,
  lib,
  ...
}:
{
  flake.nixosConfigurations.fw0 = lib.nixosSystem {
    modules = [
      (
        { lib, ... }:
        let
          inherit (lib.attrsets) attrValues;
        in
        {
          imports = attrValues self.nixosModules ++ [
            inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
            ./services.nix
            ./hardware.nix
          ];

          # Server: isDesktop defaults false, stated for clarity.
          networking.hostName = "fw0";
          isDesktop = false;
          primaryUser = "max";

          system.stateVersion = "26.05";
        }
      )
    ];
  };
}
