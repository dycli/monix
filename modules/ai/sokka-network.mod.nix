# The assistants' computers' host: the microvm.nix runner and their
# network, a host-only bridge with NAT to the internet and nothing else.
# A computer reaches any public address and no private one: not the host,
# the LAN, the tailnet or another computer; the host reaches each
# computer for its browser (MCP) and screen (VNC). The forward chain is
# closed by default, so nothing else on the host routes.
{ self, inputs, ... }:
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
      imports = singleton inputs.microvm.nixosModules.host;
      microvm.host.enable = true;
      # Its own subvolume on water (water.mod.nix): the computers' disks.
      microvm.stateDir = "/var/lib/agents/microvms";

      # networkd owns the computers' links. A headless host also gives it
      # the uplink; a desktop leaves that link to NetworkManager, which
      # then supplies the network-online target networkd cannot.
      networking.useNetworkd = true;
      networking.networkmanager.unmanaged = mkIf config.networking.networkmanager.enable [
        "interface-name:${bridge}"
        "interface-name:pc-*"
      ];
      systemd.network.wait-online.enable = !config.networking.networkmanager.enable;
      systemd.network.networks."10-uplink" = mkIf (!config.networking.networkmanager.enable) {
        matchConfig.Name = "en*";
        networkConfig.DHCP = "yes";
        linkConfig.RequiredForOnline = "routable";
      };

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
      # The NAT module appends its own blanket accept for the bridge; the
      # drop here comes first and keeps the fence.
      networking.firewall.extraForwardRules = ''
        iifname "${bridge}" ip daddr != { ${concatStringsSep ", " private} } accept comment "the assistants' computers reach the internet only"
        iifname "${bridge}" drop comment "and nothing private: not the host's networks, the tailnet or each other"
      '';

      assertions = singleton {
        assertion = !(lib.lists.elem bridge config.networking.firewall.trustedInterfaces);
        message = "${bridge} must never be a trusted firewall interface";
      };
    };
}
