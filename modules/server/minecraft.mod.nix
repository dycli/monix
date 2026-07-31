# One declarative Fabric server, tailnet-only, with server-side mods; the
# players run stock clients. Every jar is pinned by URL and sha512 from
# Modrinth against the pinned game version.
#
# online-mode requires the public Mojang session servers, so the fence
# below allows the internet while denying loopback, the LAN and the
# agent-fleet bridge.
{ self, inputs, ... }:
{
  flake.nixosModules.default = self.nixosModules.minecraft;
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

      # The server pin, every mod hash below and the players' clients move
      # together; pin an exact package, never a floating alias. The jre
      # override is required because 26.x class files need Java 25 while
      # nix-minecraft wraps this server with Java 21.
      serverPackage = pkgs.fabricServers.fabric-26_2.override {
        jre_headless = pkgs.jdk25_headless;
      };

      dataDir = config.services.minecraft-servers.dataDir; # /srv/minecraft
      worldDir = "${dataDir}/main"; # per-server subdir == the server name below

      # Pinned by CDN URL and the sha512 Modrinth's API reports.
      mod =
        {
          url,
          sha512,
        }:
        pkgs.fetchurl { inherit url sha512; };

      # All checked against Modrinth metadata for 26.2 + fabric, server_side.
      mods = {
        # Lithium — game-logic optimization.
        Lithium = mod {
          url = "https://cdn.modrinth.com/data/gvQqBUqZ/versions/UPNexAfy/lithium-fabric-0.25.2%2Bmc26.2.jar";
          sha512 = "db676376c05b7e912cdae5aad9e51f125adc1554ae2b204599ccb598751921aedbac98e97b9cba0333b6b52488c6b75c915a7dbd50436f97800387fe1aad1c50";
        };
        # FerriteCore — shares block-state and model data to cut RAM.
        FerriteCore = mod {
          url = "https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar";
          sha512 = "d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584";
        };
        # Krypton — network stack optimization.
        Krypton = mod {
          url = "https://cdn.modrinth.com/data/fQEb0iXm/versions/5WeL0Nkz/krypton-0.3.1.jar";
          sha512 = "b8d9af34cd0050493afb8a6232cb8f785daa9d8887b7045f6e6a53c6bb9b5ffc4318fd9b0347a940eacfeba4773f10cb80ae0be1e79ce4c1888f96eda21e564e";
        };

        # Spark — profiler and tick monitor, driven by /spark in game.
        Spark = mod {
          url = "https://cdn.modrinth.com/data/l6YH9Als/versions/iYFOl6lQ/spark-1.10.173-fabric.jar";
          sha512 = "1dcbf2b76ceacf07523afaeaf63d3625b0318077cc6ce588bb701aea4a494bc2a5179fd2ca5aeda9513c6a2248c2ec590387e8aec6ac9fd8e3d01760bbc3dbfb";
        };

        # ServerCore — async chunk work and dynamic view distance under load.
        ServerCore = mod {
          url = "https://cdn.modrinth.com/data/4WWQxlQP/versions/edrtnY9v/servercore-fabric-1.5.19%2B26.2.jar";
          sha512 = "aa4cfc93f8e02172910302444330e37713dfcf2047d28e55eb7323a3cd5d51493374a0959aa3e626ec2bf43fc707a755508b83454bb34b6d57d65c069929074b";
        };
        # Chunksmith — pre-generates chunks so exploration does not stutter.
        Chunksmith = mod {
          url = "https://cdn.modrinth.com/data/4BeAEBIb/versions/StOy04qm/chunksmith-3.1.1%2B26.2.jar";
          sha512 = "b8bbcd54e064e6a1b33a5ae290077ccff79b5430624271772d82a368670b2474ce2f2c3cd95318778ee7b4c3e5fd5cbc511d43459bb7862c67668e4737cff8d7";
        };

        # Required at runtime by Chunksmith, ServerCore and spark, declared
        # in those mods' own fabric.mod.json rather than anywhere here.
        # Removing it fails mod resolution and the server will not start.
        FabricAPI = mod {
          url = "https://cdn.modrinth.com/data/P7dR8mSH/versions/lVXlbH4w/fabric-api-0.155.2%2B26.2.jar";
          sha512 = "cc56984378a27c5bcd56374d6ffbb27a45c6bf3355add2ac6be9817ccac5854362249bf9d0147eb271a70fda2716129204e240d53c9aa876a2a7861f4c7f880f";
        };
      };
    in
    {
      # Inert until enabled below, so importing it everywhere is safe.
      imports = singleton inputs.nix-minecraft.nixosModules.minecraft-servers;

      options.minecraft.enable = mkEnableOption "the declarative tailnet-only Fabric Minecraft server";

      config = mkIf cfg.enable {
        # Mojang's EULA applies to the server jar underneath Fabric.
        unfreePackages = singleton "minecraft-server";

        # Brings fabricServers and the launcher wrapper into scope.
        nixpkgs.overlays = singleton inputs.nix-minecraft.overlay;

        services.minecraft-servers = {
          enable = true;

          # systemd-socket rather than the default tmux, so output and
          # crashes reach the journal. Console commands go to the socket:
          # echo save-all > /run/minecraft-server/main.stdin
          managementSystem.tmux.enable = false;
          managementSystem.systemd-socket.enable = true;

          eula = true;

          # Tailnet-only; no public port.
          openFirewall = false;

          servers.main = {
            enable = true;
            autoStart = true;

            package = serverPackage;

            # Small server: start at 2G, cap at 4G — the JVM bounds itself.
            jvmOpts = "-Xms2G -Xmx4G";

            # nix-minecraft's documented pattern for a pinned jar set.
            symlinks.mods = pkgs.linkFarmFromDrvs "mods" (lib.attrsets.attrValues mods);

            # Chunksmith 3.x otherwise auto-enables an LOD store serving a
            # companion client mod nobody here runs, costing pregen speed,
            # disk and a second listener. Files rather than symlinks,
            # because the mod rewrites this config.
            files."config/chunksmith.json" = pkgs.writeText "chunksmith.json" (toJSON {
              lodEnabled = false;
            });

            # Mojang-authenticated accounts only; needs the session servers.
            serverProperties = {
              server-port = 25565;
              max-players = 5;
              difficulty = "normal";
              level-seed = "1133044835122437667"; # only consulted at world creation
              # A paused server ignores console input and freezes Chunksmith
              # pregeneration once the last player leaves.
              pause-when-empty-seconds = -1;
              online-mode = true;
              white-list = false;
              # simulation-distance stays at the vanilla 10 so ticking is
              # untouched; ServerCore walks view-distance down under load.
              # Cost grows with the square of the distance.
              view-distance = 20;
              motd = "fw0 // tailnet survival — stock clients welcome";
              # The firewall, not the bind address, keeps this tailnet-only.
              server-ip = "";
            };
          };
        };

        # nix-minecraft already sandboxes this unit; only the directives it
        # leaves out are added here.
        systemd.services.minecraft-server-main.serviceConfig = {

          # worldDir is then the only writable path; RuntimeDirectory stays
          # writable automatically.
          ProtectSystem = "strict";
          ReadWritePaths = [ worldDir ];
          NoNewPrivileges = true;
          # ProcSubset=pid would hide /proc/mounts, which Java's NIO needs
          # for file-store lookups; world loading then fails with "Mount
          # point not found". ProtectProc=invisible still hides other
          # processes.
          RemoveIPC = true;
          UMask = lib.mkForce "0077"; # tighter than upstream's 0007 (no group access)

          # MemoryDenyWriteExecute is unset because the JVM JIT needs W+X.
          #
          # Spark's async-profiler probes perf_event_open, outside
          # @system-service. The default seccomp action kills the JVM
          # mid-startup and can leave a half-written world; EPERM lets the
          # probe fail and Spark fall back to its Java sampler.
          SystemCallFilter = [ "@system-service" ];
          SystemCallErrorNumber = "EPERM";

          # The tailnet is allowed and private ranges denied; the public
          # internet falls through for Mojang session auth.
          IPAddressAllow = [
            "100.64.0.0/10" # tailnet (CGNAT range)
            # resolved's stub, which the loopback deny below would
            # otherwise block; nothing else binds this address.
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
