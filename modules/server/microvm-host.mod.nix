# Agent-fleet microVM host (docs/agent-fleet.md). Provides the microvm.nix
# host runner, a HOST-ONLY bridge `br-agents` (10.100.0.1/24, no NAT/routing/
# DNS for guests), and `squid` as the sole egress path (CONNECT allowlist +
# audit log). Guests have no default route or DNS, so squid is structurally
# the only way out — default-deny by construction, not just policy.
#
# Networking touches ONLY br-agents and vm-* taps via systemd-networkd; host
# uplinks stay on dhcpcd (`dhcpcd.denyInterfaces` keeps the two managers from
# fighting), so a misconfigured bridge can't take down uplinks or SSH.
{ inputs, ... }:
{
  flake.nixosModules.microvm-host =
    {
      config,
      lib,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf mkMerge;
      inherit (lib.options) mkEnableOption;
      inherit (lib.strings) concatStringsSep;

      cfg = config.agentFleet;
      topology = import ../../lib/fleet-topology.nix;
      inherit (topology) bridge hostAddr;

      # The ONLY destinations a guest can reach; widen only by reviewed
      # commit. A leading-dot dstdomain matches the domain and all
      # subdomains, so don't also list specific hosts (squid rejects the
      # redundancy).
      allowedDomains = [
        ".anthropic.com" # Claude API + Claude Code auth/telemetry
        ".openai.com" # Codex: OpenAI API + auth
        ".chatgpt.com" # Codex: ChatGPT-subscription backend/auth
        ".openrouter.ai" # opencode: OpenRouter API (any-model dispatch)
        ".models.dev" # opencode: provider/model registry it fetches at startup
        "cache.nixos.org" # exact trusted binary cache; not user-content *.nixos.org
      ];
    in
    {
      imports = singleton inputs.microvm.nixosModules.host;

      options.agentFleet.enable = mkEnableOption "the agent-fleet microVM host role";

      config = mkMerge [
        # microvm.nix's host runner defaults ON once its module is imported,
        # and this aspect loads on every host, so gate it explicitly.
        { microvm.host.enable = cfg.enable; }

        (mkIf cfg.enable {
          # Guest state on the dedicated @agents dataset, not the root subvol.
          microvm.stateDir = "/var/lib/agents/microvms";

          # If install-microvm is interrupted before chowning a worker's state
          # dir, it's left root-owned and microvm-set-booted fails with EACCES,
          # aborting the whole activation (broke the jump 2->12). This tmpfiles
          # `d` rule sets/repairs ownership early, before the microvm units.
          systemd.tmpfiles.rules = map (
            w: "d ${config.microvm.stateDir}/${w.name} 0755 microvm kvm -"
          ) cfg.workers;

          # Full systemd-networkd, not mixed with scripted dhcpcd (NixOS warns
          # this can drop networking): networkd becomes authoritative for all
          # interfaces, so the onboard uplink is configured explicitly too.
          networking.useNetworkd = true;

          boot.kernel.sysctl = {
            "net.ipv4.ip_forward" = 0;
            "net.ipv6.conf.all.forwarding" = 0;
          };

          assertions = [
            {
              assertion = !(lib.lists.elem bridge config.networking.firewall.trustedInterfaces);
              message = "br-agents must never be a trusted firewall interface";
            }
          ];

          # tailscale0 is left to tailscaled (no match here); lo is networkd's default.
          systemd.network.networks."10-uplink" = {
            matchConfig.Name = "en*";
            networkConfig.DHCP = "yes";
            linkConfig.RequiredForOnline = "routable";
          };

          # No uplink port is ever enslaved to this bridge, so it can't route
          # anywhere; RequiredForOnline=no so a carrier-less bridge never blocks boot.
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

          systemd.network.networks."31-agent-taps" = {
            matchConfig.Name = "vm-*";
            networkConfig.Bridge = bridge;
            linkConfig.RequiredForOnline = "no";
            # Isolated ports cannot forward to other isolated ports at L2, but
            # can still deliver to the bridge master (the host). This drops
            # guest↔guest traffic while leaving guest→host:3128 (squid) intact.
            bridgeConfig.Isolated = true;
          };

          # From the bridge, guests may reach only squid, plus (when serving
          # local inference) llama-swap — a deliberate pinhole, sandboxed like
          # squid since it also parses untrusted guest bytes (inference.mod.nix).
          # br-agents is NOT a trusted interface, so default DROP covers
          # everything else; belt-and-braces since IP forwarding is off anyway.
          networking.firewall.interfaces.${bridge}.allowedTCPPorts = [
            3128
          ]
          ++ lib.lists.optionals config.inference.enable [ config.inference.port ];

          # The single audited egress point, bound to the bridge IP only.
          services.squid = {
            enable = true;
            configText = ''
              http_port ${hostAddr}:3128
              pid_filename /run/squid/squid.pid

              # Run as the squid user (owns /var/log/squid + /var/cache/squid);
              # without this squid drops to 'nobody' and can't write its logs.
              cache_effective_user squid

              acl allowed_domains dstdomain ${concatStringsSep " " allowedDomains}
              acl SSL_ports port 443
              acl CONNECT method CONNECT

              # HTTPS CONNECT only. Plain HTTP would expose payloads and is not
              # needed by any sealed-worker provider or binary-cache endpoint.
              http_access deny !CONNECT
              http_access deny CONNECT !SSL_ports
              http_access allow allowed_domains
              http_access deny all

              # Proxy, not cache.
              cache deny all

              # THIS is the egress audit trail: one line per request.
              access_log stdio:/var/log/squid/access.log
              cache_log stdio:/var/log/squid/cache.log
              coredump_dir /var/cache/squid
            '';
          };
          # squid parses bytes from untrusted guests — the one crack in the
          # otherwise-clean KVM boundary — so it's sandboxed to an empty room:
          # read-only filesystem except logs/cache/pidfile, no new privileges,
          # only the capabilities needed to drop from root at startup.
          systemd.services.squid.serviceConfig = {
            Slice = "agents.slice";

            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            # ProtectSystem=strict leaves /run read-only, so the pidfile moves
            # into a RuntimeDirectory (realigned from upstream's /run/squid.pid).
            RuntimeDirectory = "squid";
            PIDFile = lib.mkForce "/run/squid/squid.pid";
            ReadWritePaths = [
              "/var/log/squid"
              "/var/cache/squid"
            ];
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
              "AF_NETLINK"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "@setuid"
              "@chown"
            ];
            CapabilityBoundingSet = [
              "CAP_SETUID"
              "CAP_SETGID"
              "CAP_CHOWN"
              "CAP_DAC_OVERRIDE"
            ];
          };
        })
      ];
    };
}
