# usage: every subscription's limits, from the host's usage service
# (modules/ai/usage.mod.nix), so a session can plan model-heavy runs.
{
  flake.homeModules.cockpit =
    { lib, pkgs, ... }:
    {
      home.packages = lib.lists.singleton (
        pkgs.writeShellApplication {
          name = "usage";
          runtimeInputs = [ pkgs.socat ];
          text = "socat -t 60 -T 60 - UNIX-CONNECT:/run/usage.sock < /dev/null";
        }
      );
    };
}
