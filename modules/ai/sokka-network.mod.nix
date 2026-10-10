# The assistants' computers' network: a host-only bridge with NAT to the
# internet and nothing else. A computer reaches any public address and
# no private one: not the host, the LAN, the tailnet or another
# computer; the host reaches each computer for its browser (MCP) and
# screen (VNC). The forward chain is closed by default, which also keeps
# the fleet's drones (host.mod.nix) unable to route now that forwarding
# is on for this bridge.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.sokka-network;
  flake.nixosModules.sokka-network =
    { config, lib, ... }:
    let
      inherit (lib.lists) filter singleton;
      inherit (lib.strings) hasInfix;
      inherit (lib.modules) mkIf;
      inherit (lib.strings) concatStringsSep;
      inherit (lib.ship) computers fences;
      inherit (computers) bridge hostAddr;
      # Guests have IPv4 only; an nft set cannot mix families.
      private = filter (r: !hasInfix ":" r) (fences.privateRanges ++ singleton fences.tailnet);
    in
    {
      networking.networkmanager.unmanaged = mkIf config.networking.networkmanager.enable [
        "interface-name:${bridge}"
        "interface-name:pc-*"
      ];

      systemd.network.netdevs."30-${bridge}".netdevConfig = {
        Name = bridge;
        Kind = "bridge";
      };
      systemd.network.networks."30-${bridge}" = {
        matchConfig.Name = bridge;
        address = singleton "${hostAddr}/24";
        networkConfig.ConfigureWithoutCarrier = true;
        linkConfig.RequiredForOnline = "no";
      };
      systemd.network.networks."31-pc-taps" = {
        matchConfig.Name = "pc-*";
        networkConfig.Bridge = bridge;
        linkConfig.RequiredForOnline = "no";
        # Computers cannot see each other at L2 either.
        bridgeConfig.Isolated = true;
      };

      networking.nat = {
        enable = true;
        internalInterfaces = singleton bridge;
      };
      networking.firewall.filterForward = true;
      networking.firewall.extraForwardRules = ''
        iifname "${bridge}" ip daddr != { ${concatStringsSep ", " private} } accept comment "the assistants' computers reach the internet only"
      '';

      assertions = singleton {
        assertion = !(lib.lists.elem bridge config.networking.firewall.trustedInterfaces);
        message = "${bridge} must never be a trusted firewall interface";
      };
    };
}
