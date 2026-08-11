# Agent-fleet microVM host: the microvm.nix runner, the host-only br-agents
# bridge, and squid as the guests' only egress.
{ self, inputs, ... }:
{
  flake.nixosModules.lab = self.nixosModules.microvm-host;
  flake.nixosModules.microvm-host =
    {
      config,
      lib,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.strings) concatStringsSep;

      cfg = config.agentFleet;
      inherit (lib.ship) topology;
      inherit (topology) bridge hostAddr;

      # The only destinations a guest can reach. A leading-dot dstdomain
      # covers the domain and its subdomains.
      allowedDomains = [
        ".anthropic.com"
        ".openai.com"
        ".chatgpt.com"
        ".openrouter.ai"
        ".models.dev" # opencode fetches its provider registry at startup
        "cache.nixos.org" # exact: *.nixos.org carries user content
      ];

      # On a dedicated loopback address so the seat's fence can admit this
      # listener without admitting the services on 127.0.0.1.
      seatDomains = allowedDomains ++ [
        ".claude.ai"
        ".claude.com"
        ".github.com"
        ".githubusercontent.com"
        ".crates.io"
        "channels.nixos.org"
      ];
      seatProxy = "${topology.seatProxyAddr}:${toString topology.seatProxyPort}";
    in
    {
      imports = singleton inputs.microvm.nixosModules.host;

      config = {
        # The host runner defaults on once the module is imported.
        microvm.host.enable = true;

        microvm.stateDir = "/var/lib/agents/microvms";

        # An interrupted install-microvm leaves a state dir root-owned, and
        # microvm-set-booted then fails with EACCES and aborts activation.
        systemd.tmpfiles.rules = map (
          w: "d ${config.microvm.stateDir}/${w.name} 0755 microvm kvm -"
        ) cfg.workers;

        # networkd is authoritative for every interface here; mixing in
        # scripted dhcpcd can drop networking.
        networking.useNetworkd = true;

        boot.kernel.sysctl = {
          "net.ipv4.ip_forward" = 0;
          "net.ipv6.conf.all.forwarding" = 0;
        };

        assertions = singleton {
          assertion = !(lib.lists.elem bridge config.networking.firewall.trustedInterfaces);
          message = "br-agents must never be a trusted firewall interface";
        };

        systemd.network.networks."10-uplink" = {
          matchConfig.Name = "en*";
          networkConfig.DHCP = "yes";
          linkConfig.RequiredForOnline = "routable";
        };

        # No uplink port is enslaved to this bridge, so it cannot route.
        # RequiredForOnline=no keeps a carrier-less bridge from blocking
        # boot.
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
          # reach the bridge master: guest-to-guest is dropped,
          # guest-to-squid works.
          bridgeConfig.Isolated = true;
        };

        networking.firewall.interfaces.${bridge}.allowedTCPPorts = [
          3128
          config.inference.port
        ];

        services.squid = {
          enable = true;
          configText = ''
            http_port ${hostAddr}:3128
            http_port ${seatProxy}
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
            # Valid only on the seat's own listener, not the workers' port.
            acl seat_port localport ${toString topology.seatProxyPort}
            acl seat_domains dstdomain ${concatStringsSep " " seatDomains}
            http_access allow seat_domains seat_port

            http_access deny all

            # Proxy, not cache.
            cache deny all

            # The egress audit trail: one line per request.
            access_log stdio:/var/log/squid/access.log
            cache_log stdio:/var/log/squid/cache.log
            coredump_dir /var/cache/squid
          '';
        };
        # squid parses bytes from untrusted guests: only the capabilities
        # needed to drop from root.
        systemd.services.squid.serviceConfig = {

          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          # ProtectSystem=strict leaves /run read-only, so the pidfile moves
          # into a RuntimeDirectory.
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
      };
    };
}
