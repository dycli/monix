{
  flake.nixosModules.ssh =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
    in
    {
      services.openssh = {
        enable = true;

        # Servers reach sshd over the tailnet only, since tailscale0 is a
        # trusted interface; port 22 never opens publicly. Desktops keep
        # the default open port for the LAN.
        openFirewall = mkIf (!config.isDesktop) (mkDefault false);

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
