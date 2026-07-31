{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.ssh;
  flake.nixosModules.ssh =
    { lib, ... }:
    let
      inherit (lib.modules) mkDefault;
    in
    {
      services.openssh = {
        enable = true;

        # Desktops keep the default open port for the LAN; the homelab
        # bundle closes it (tailnet-only, tailscale0 is trusted).

        settings = {
          PasswordAuthentication = mkDefault false;
          KbdInteractiveAuthentication = mkDefault false;
          PermitRootLogin = mkDefault "no";
        };
      };

      # Root has no authorized keys and PermitRootLogin=no forbids root SSH
      # outright, so a stray key could not enable it. Admin access is the
      # primary user plus sudo.
    };
}
