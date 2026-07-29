# Minecraft server aspect — one declarative Fabric server, server-side mods
# only, reachable over the tailnet and nowhere else. Inert until a host sets
# `minecraft.enable`.
#
# Threat model: a Minecraft server is a JVM parsing untrusted bytes from every
# connecting player, running a mod loader — treat full compromise as
# plausible. Reachability is tailnet-only (openFirewall = false, no LAN/WAN
# exposure). Blast radius is limited by the nix-minecraft sandbox, tightened
# further below (ProtectSystem=strict, empty caps, syscall allowlist). The
# egress fence below is the key control: online-mode needs the public Mojang
# session servers, but the service must not be able to reach localhost, the
# home LAN, or the agent-fleet microVM bridge.
#
# Mods are server-side only (players use stock vanilla clients). Every jar is
# pinned by URL + sha512 from Modrinth, verified against the pinned Minecraft
# version from Modrinth's own metadata.
{ inputs, ... }:
{
  flake.nixosModules.minecraft =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.strings) toJSON;
      inherit (lib.options) mkEnableOption;

      cfg = config.minecraft;
      networkFences = import ../../lib/network-fences.nix;

      # Bump rule: server pin, every mod hash below, and players' clients move
      # together. Pin the exact package (fabric-26_2), never a floating alias.
      # jre override: Minecraft 26.x class files need Java 25, but
      # nix-minecraft's package wraps this server with a Java 21 runtime,
      # which dies at launch with UnsupportedClassVersionError.
      serverPackage = pkgs.fabricServers.fabric-26_2.override {
        jre_headless = pkgs.jdk25_headless;
      };

      dataDir = config.services.minecraft-servers.dataDir; # /srv/minecraft
      worldDir = "${dataDir}/main"; # per-server subdir == the server name below

      # A Modrinth mod jar, pinned by CDN URL + sha512 (the hash Modrinth's API reports).
      mod =
        {
          url,
          sha512,
        }:
        pkgs.fetchurl { inherit url sha512; };

      # Every version below was checked against Modrinth metadata for
      # game_version 26.2 + loader "fabric"; all are server_side.
      mods = {
        # --- Performance (the reason this list exists) ---
        # Lithium — general game-logic optimization. No dependencies.
        Lithium = mod {
          url = "https://cdn.modrinth.com/data/gvQqBUqZ/versions/UPNexAfy/lithium-fabric-0.25.2%2Bmc26.2.jar";
          sha512 = "db676376c05b7e912cdae5aad9e51f125adc1554ae2b204599ccb598751921aedbac98e97b9cba0333b6b52488c6b75c915a7dbd50436f97800387fe1aad1c50";
        };
        # FerriteCore — cuts server RAM use (shared block-state/model data).
        FerriteCore = mod {
          url = "https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar";
          sha512 = "d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584";
        };
        # Krypton — network stack optimization. No dependencies.
        Krypton = mod {
          url = "https://cdn.modrinth.com/data/fQEb0iXm/versions/5WeL0Nkz/krypton-0.3.1.jar";
          sha512 = "b8d9af34cd0050493afb8a6232cb8f785daa9d8887b7045f6e6a53c6bb9b5ffc4318fd9b0347a940eacfeba4773f10cb80ae0be1e79ce4c1888f96eda21e564e";
        };

        # --- Observability ---
        # Spark — profiler / tick + memory monitor. In-game `/spark` commands.
        Spark = mod {
          url = "https://cdn.modrinth.com/data/l6YH9Als/versions/iYFOl6lQ/spark-1.10.173-fabric.jar";
          sha512 = "1dcbf2b76ceacf07523afaeaf63d3625b0318077cc6ce588bb701aea4a494bc2a5179fd2ca5aeda9513c6a2248c2ec590387e8aec6ac9fd8e3d01760bbc3dbfb";
        };

        # --- Quality of life (low-touch, server-side, non-gameplay-altering) ---
        # ServerCore — server-only performance/QoL tuning (async chunk work,
        # dynamic view distance under load). No dependencies. No client needed.
        ServerCore = mod {
          url = "https://cdn.modrinth.com/data/4WWQxlQP/versions/edrtnY9v/servercore-fabric-1.5.19%2B26.2.jar";
          sha512 = "aa4cfc93f8e02172910302444330e37713dfcf2047d28e55eb7323a3cd5d51493374a0959aa3e626ec2bf43fc707a755508b83454bb34b6d57d65c069929074b";
        };
        # Chunksmith — admin convenience: pre-generate chunks so exploration
        # doesn't stutter. Server-side only, no dependencies.
        Chunksmith = mod {
          url = "https://cdn.modrinth.com/data/4BeAEBIb/versions/StOy04qm/chunksmith-3.1.1%2B26.2.jar";
          sha512 = "b8bbcd54e064e6a1b33a5ae290077ccff79b5430624271772d82a368670b2474ce2f2c3cd95318778ee7b4c3e5fd5cbc511d43459bb7862c67668e4737cff8d7";
        };

        # --- Library ---
        # Fabric API — no current mod requires it, but most Fabric mods do,
        # so keeping it means future additions just work. Inert on its own.
        FabricAPI = mod {
          url = "https://cdn.modrinth.com/data/P7dR8mSH/versions/lVXlbH4w/fabric-api-0.155.2%2B26.2.jar";
          sha512 = "cc56984378a27c5bcd56374d6ffbb27a45c6bf3355add2ac6be9817ccac5854362249bf9d0147eb271a70fda2716129204e240d53c9aa876a2a7861f4c7f880f";
        };
      };
    in
    {
      # Upstream module stays inert until enabled below, so importing it
      # unconditionally on every host is safe.
      imports = singleton inputs.nix-minecraft.nixosModules.minecraft-servers;

      options.minecraft.enable = mkEnableOption "the declarative tailnet-only Fabric Minecraft server";

      config = mkIf cfg.enable {
        # Brings pkgs.fabricServers and the launcher wrapper into scope, from
        # nix-minecraft's own pinned nixpkgs (see flake.nix).
        nixpkgs.overlays = singleton inputs.nix-minecraft.overlay;

        services.minecraft-servers = {
          enable = true;

          # systemd-socket, not the default tmux: the server runs in the
          # foreground so console output (and crashes) land in the journal
          # instead of a detached tmux session. Console commands go via the
          # socket: `echo save-all > /run/minecraft-server/main.stdin`.
          managementSystem.tmux.enable = false;
          managementSystem.systemd-socket.enable = true;

          eula = true;

          # No public port — reachability is tailnet-only by construction; the load-bearing firewall statement.
          openFirewall = false;

          servers.main = {
            enable = true;
            autoStart = true;

            package = serverPackage;

            # Small server: start at 2G, cap at 4G, within the services.slice 16G fence.
            jvmOpts = "-Xms2G -Xmx4G";

            # linkFarmFromDrvs over the pinned jars is nix-minecraft's
            # documented pattern; reproducible from the hashes above.
            symlinks.mods = pkgs.linkFarmFromDrvs "mods" (lib.attrsets.attrValues mods);

            # Chunksmith 3.x auto-enables its LOD store on dedicated servers
            # (slower pregen, extra disk, a second listener) serving the
            # Chunksmith-Client companion mod our stock-vanilla players don't
            # run. Off. files, not symlinks: the mod rewrites this config.
            files."config/chunksmith.json" = pkgs.writeText "chunksmith.json" (toJSON {
              lodEnabled = false;
            });

            # online-mode true means Mojang-authenticated accounts only (why
            # the egress fence must permit the Mojang session servers).
            serverProperties = {
              server-port = 25565;
              max-players = 5;
              difficulty = "normal";
              level-seed = "1133044835122437667"; # only consulted at world creation
              # Never pause when empty: a paused server ignores console input
              # and freezes Chunksmith pregeneration once the last player leaves.
              pause-when-empty-seconds = -1;
              online-mode = true;
              white-list = false;
              # simulation-distance stays at the vanilla default (10) so
              # ticking is untouched; ServerCore walks view-distance back down
              # if tick rate suffers. Cost grows with the square of the
              # distance — think before going higher than 20.
              view-distance = 20;
              motd = "fw0 // tailnet survival — stock clients welcome";
              # Bind to all interfaces: the firewall, not the bind address, keeps this tailnet-only.
              server-ip = "";
            };
          };
        };

        # nix-minecraft already ships a strong sandbox (unprivileged user,
        # empty caps/DeviceAllow, Private{Devices,Tmp,Users}, Protect*,
        # Restrict{AddressFamilies,Namespaces,Realtime,SUIDSGID}). We add
        # only the directives it leaves out, plus the egress fence.
        systemd.services.minecraft-server-main.serviceConfig = {
          Slice = "services.slice";

          # ProtectSystem=strict makes the whole filesystem read-only except
          # named paths, so worldDir is the only writable place.
          # RuntimeDirectory=/run/minecraft stays writable automatically.
          ProtectSystem = "strict";
          ReadWritePaths = [ worldDir ];
          NoNewPrivileges = true;
          # No ProcSubset=pid: it hides /proc/mounts, which Java's NIO needs
          # for file-store lookups — world/datapack loading otherwise dies
          # with "Mount point not found". Upstream ProtectProc=invisible still
          # hides other processes' entries.
          RemoveIPC = true;
          UMask = lib.mkForce "0077"; # tighter than upstream's 0007 (no group access)

          # MemoryDenyWriteExecute is deliberately unset: the JVM JIT needs W+X pages.
          #
          # EPERM instead of kill-on-violation: Spark's native async-profiler
          # probes perf_event_open (outside @system-service); the default
          # seccomp action kills the JVM mid-startup, which can leave a
          # half-written world that breaks every restart. EPERM lets the
          # probe fail gracefully and Spark fall back to its Java sampler.
          SystemCallFilter = [ "@system-service" ];
          SystemCallErrorNumber = "EPERM";

          # Anti-pivot egress fence — the key control. systemd checks
          # IPAddressAllow before IPAddressDeny; unmatched traffic is
          # allowed. So: allow the tailnet, deny every private/loopback/
          # link-local range (covers the agent-fleet bridge 10.100.0.0/24),
          # and let the public internet (Mojang session/auth) fall through
          # as allowed.
          IPAddressAllow = [
            "100.64.0.0/10" # tailnet (CGNAT range)
            # systemd-resolved's stub resolver: the JVM resolves Mojang's
            # session servers via 127.0.0.53, which the loopback deny below
            # would otherwise block. Nothing else binds this address.
            "127.0.0.53/32"
          ];
          IPAddressDeny = [
            "127.0.0.0/8" # loopback / other localhost services
            "::1"
          ]
          ++ networkFences.privateRanges;
        };
      };
    };
}
