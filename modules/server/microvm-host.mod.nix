# Agent-fleet microVM host: the microvm.nix runner, a host-only bridge
# br-agents (10.100.0.1/24, with no NAT, routing or DNS for guests), and
# squid as the only egress. Guests have no default route or DNS, so squid
# is the sole exit by construction.
#
# networkd owns br-agents, the vm-* taps and the onboard uplink; scripted
# dhcpcd is not mixed in. tailscale0 stays with tailscaled.
{ self, inputs, ... }:
{
  flake.nixosModules.default = self.nixosModules.microvm-host;
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
      inherit (lib.strings) concatStringsSep optionalString;

      cfg = config.agentFleet;
      inherit (lib.ship) topology;
      inherit (topology) bridge hostAddr;

      # The only destinations a guest can reach. A leading-dot dstdomain
      # covers the domain and its subdomains; squid rejects listing a
      # specific host as well.
      allowedDomains = [
        ".anthropic.com" # Claude API + Claude Code auth/telemetry
        ".openai.com" # Codex: OpenAI API + auth
        ".chatgpt.com" # Codex: ChatGPT-subscription backend/auth
        ".openrouter.ai" # opencode: OpenRouter API (any-model dispatch)
        ".models.dev" # opencode: provider/model registry it fetches at startup
        "cache.nixos.org" # exact trusted binary cache; not user-content *.nixos.org
      ];

      # Wider than the workers' list, on a dedicated loopback address so
      # the seat's fence can admit this listener without admitting the
      # services on 127.0.0.1. Named "seat" here because `bridge` already
      # means br-agents in this file.
      seatDomains = allowedDomains ++ [
        ".claude.ai" # Claude Code session sync/artifacts
        ".claude.com" # Claude Code OAuth (claude.com + platform.claude.com)
        ".github.com" # git remotes + gh api
        ".githubusercontent.com" # raw files, release assets, flake registry
        ".crates.io" # cargo index + downloads
        "channels.nixos.org" # nixpkgs channel/flake metadata
      ];
      seatProxy = "${topology.seatProxyAddr}:${toString topology.seatProxyPort}";
    in
    {
      imports = singleton inputs.microvm.nixosModules.host;

      options.agentFleet.enable = mkEnableOption "the agent-fleet microVM host role";

      config = mkMerge [
        # The host runner defaults on once the module is imported, and this
        # aspect loads everywhere, so it is gated explicitly.
        { microvm.host.enable = cfg.enable; }

        (mkIf cfg.enable {
          # Guest state lives on the @agents subvolume.
          microvm.stateDir = "/var/lib/agents/microvms";

          # An interrupted install-microvm leaves a state dir root-owned,
          # and microvm-set-booted then fails with EACCES and aborts the
          # activation. This repairs ownership before the microvm units run.
          systemd.tmpfiles.rules = map (
            w: "d ${config.microvm.stateDir}/${w.name} 0755 microvm kvm -"
          ) cfg.workers;

          # networkd is authoritative for every interface, so the onboard
          # uplink is configured here too; mixing in scripted dhcpcd can
          # drop networking.
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

          # tailscale0 is left to tailscaled; lo is networkd's default.
          systemd.network.networks."10-uplink" = {
            matchConfig.Name = "en*";
            networkConfig.DHCP = "yes";
            linkConfig.RequiredForOnline = "routable";
          };

          # No uplink port is enslaved to this bridge, so it cannot route.
          # RequiredForOnline=no keeps a carrier-less bridge from blocking boot.
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
            # Isolated ports cannot forward to each other at L2 but still
            # reach the bridge master, so guest-to-guest traffic is dropped
            # while guest-to-squid still works.
            bridgeConfig.Isolated = true;
          };

          # Guests may reach squid and, when local inference is served,
          # llama-swap. br-agents is not a trusted interface, so everything
          # else is dropped by default.
          networking.firewall.interfaces.${bridge}.allowedTCPPorts = [
            3128
          ]
          ++ lib.lists.optionals config.inference.enable [ config.inference.port ];

          # Bound to the bridge IP only.
          services.squid = {
            enable = true;
            configText = ''
              http_port ${hostAddr}:3128
              ${optionalString config.cockpit.enable "http_port ${seatProxy}"}
              pid_filename /run/squid/squid.pid

              # Without this squid drops to 'nobody' and cannot write its
              # own logs or cache.
              cache_effective_user squid

              acl fleet_port localport 3128
              acl allowed_domains dstdomain ${concatStringsSep " " allowedDomains}
              acl SSL_ports port 443
              acl CONNECT method CONNECT

              # HTTPS CONNECT only; nothing here needs plain HTTP.
              http_access deny !CONNECT
              http_access deny CONNECT !SSL_ports
              http_access allow allowed_domains fleet_port
              ${optionalString config.cockpit.enable ''
                # Valid only on the seat's own listener, not the workers' port.
                acl seat_port localport ${toString topology.seatProxyPort}
                acl seat_domains dstdomain ${concatStringsSep " " seatDomains}
                http_access allow seat_domains seat_port
              ''}
              http_access deny all

              # Proxy, not cache.
              cache deny all

              # The egress audit trail: one line per request.
              access_log stdio:/var/log/squid/access.log
              cache_log stdio:/var/log/squid/cache.log
              coredump_dir /var/cache/squid
            '';
          };
          # squid parses bytes from untrusted guests, so it keeps only the
          # capabilities needed to drop from root and a filesystem that is
          # read-only apart from its logs, cache and pidfile.
          systemd.services.squid.serviceConfig = {

            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            # ProtectSystem=strict leaves /run read-only, so the pidfile
            # moves into a RuntimeDirectory.
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
