{ self, ... }:
{
  # Root has no authorized keys and PermitRootLogin=no forbids root SSH
  # outright, so a stray key could not enable it. Admin access is the
  # primary user plus sudo.
  flake.commonModules.default = self.commonModules.ssh;
  flake.commonModules.ssh = {
    services.openssh.enable = true;
  };

  flake.nixosModules.default = self.nixosModules.ssh-linux;
  flake.nixosModules.ssh-linux =
    { lib, ... }:
    let
      inherit (lib.modules) mkDefault;
    in
    {
      services.openssh = {
        # Every host answers SSH over the tailnet only: tailscale0 is
        # trusted, so port 22 never opens on any other interface.
        openFirewall = mkDefault false;

        settings = {
          PasswordAuthentication = mkDefault false;
          KbdInteractiveAuthentication = mkDefault false;
          PermitRootLogin = mkDefault "no";
        };
      };
    };

  # Enabling it turns on macOS's Remote Login, whose sshd listens on every
  # interface, the LAN included. Keys alone admit, and only the primary user
  # may log in, so a shared Mac's other accounts are not reachable over SSH
  # whatever their passwords.
  flake.darwinModules.default = self.darwinModules.ssh-darwin;
  flake.darwinModules.ssh-darwin =
    { config, ... }:
    {
      services.openssh.extraConfig = ''
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no
        AllowUsers ${config.primaryUser}
      '';
    };
}
