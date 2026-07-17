# fw0 — Framework Desktop (Ryzen AI Max+ 395 "Strix Halo", 128GB unified
# LPDDR5X), the headless always-on AI server. Roles: agent-fleet microVM
# host (see docs/agent-fleet.md), the user's persistent cockpit session,
# and local inference. All admin and service access is tailnet-only — zero
# inbound ports on the home IP (public SSH is closed by ssh.mod.nix for
# servers; every service binds localhost or is reached via the trusted
# tailscale0 interface).
#
# BIOS (one-time, manual): enable AMD SVM (virtualization) and "restore on AC
# power loss" so the host auto-boots after an outage.
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

          # HOST CLASS (server: isDesktop defaults to false, stated for clarity)
          networking.hostName = "fw0";
          isDesktop = false;
          primaryUser = "max";

          system.stateVersion = "26.05";
        }
      )
    ];
  };
}
