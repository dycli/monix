# The fleet's binary cache: Water serves its Nix store over the tailnet with
# Harmonia, so a package Water has already built (Codex, Hex, Libri, anything
# the public caches lack) is downloaded by the other hosts instead of being
# compiled again on each. Every host lists it as a substituter after the
# public caches; the host that serves it does not. Paths are signed with
# water-1, whose secret half is an agenix secret on Water only.
#
# The listener binds the wildcard but only tailscale0 is a trusted firewall
# interface and the port is not opened, so it is reachable from the tailnet
# alone. Hosts without `binaryCache.signKeyFile` leave the server off.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.binary-cache;
  flake.nixosModules.binary-cache =
    { config, lib, ... }:
    let
      inherit (lib) types;
      inherit (lib.lists) singleton optional;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;

      port = 5080;
      serving = config.binaryCache.signKeyFile != null;
    in
    {
      options.binaryCache.signKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Secret signing key; setting it makes this host serve the fleet cache.";
      };

      config = {
        services.harmonia.cache = mkIf serving {
          enable = true;
          signKeyPaths = singleton config.binaryCache.signKeyFile;
          settings.bind = "[::]:${toString port}";
        };

        # Down or unreachable, Water is skipped after the timeout and the
        # public caches or a local build take over.
        nix.settings = {
          substituters = optional (!serving) "http://${lib.ship.topology.hostMagicDnsName}:${toString port}";
          trusted-public-keys = singleton "water-1:YRSPaunDMNnPz9LvRzhcEdSlCIlbH9BZW9tKLcH/P+M=";
          connect-timeout = 5;
        };
      };
    };
}
