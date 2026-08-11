# The remote coding-agent seat: Paseo's daemon drives the bridge account's
# already-authenticated claude/codex/opencode CLIs, reachable from phone/web
# clients over the tailnet. Runs as the unprivileged bridge user, so agents
# inherit its privilege boundary (no wheel, no Nix trust, no secrets).
{ self, inputs, ... }:
{
  flake.nixosModules.lab = self.nixosModules.paseo;
  flake.nixosModules.paseo =
    { pkgs, ... }:
    {
      imports = [ inputs.paseo.nixosModules.paseo ];

      services.paseo = {
        enable = true;
        package = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.paseo;

        # inheritUserEnvironment (default for a non-paseo user) puts
        # /etc/profiles/per-user/bridge/bin on the daemon's PATH, so the agent
        # providers resolve from the seat's authenticated installs.
        user = "bridge";
        group = "bridge";

        # bazarr owns 6767 (Paseo's default). tailscale0 is a trusted firewall
        # interface, so binding broadly with the public firewall closed leaves
        # the daemon reachable over the tailnet only.
        port = 6768;
        listenAddress = "0.0.0.0";
        openFirewall = false;

        # Direct connections only; no hosted relay.
        relay.enable = false;

        # Phone/web clients reach it by MagicDNS name; loopback and IPs are
        # always allowed regardless.
        hostnames = [ ".olm-hen.ts.net" ];
      };
    };
}
