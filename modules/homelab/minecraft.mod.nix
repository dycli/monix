# Declarative tailnet-only game servers: Fabric with server-side mods,
# plus a Better than Adventure server. Every jar is pinned by URL and hash.
#
# online-mode requires Mojang's session servers, so the fence below allows
# the internet while denying loopback, the LAN and the fleet bridge.
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
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkIf;
      inherit (lib.strings) toJSON;
      inherit (lib.options) mkEnableOption;
      inherit (lib.attrsets) attrValues mapAttrs';

      cfg = config.minecraft;
      inherit (lib.ship) fences;

      # 26.x class files need Java 25; nix-minecraft wraps this server with 21.
      serverPackage = pkgs.fabricServers.fabric-26_2.override {
        jre_headless = pkgs.jdk25_headless;
      };

      dataDir = config.services.minecraft-servers.dataDir;

      mod =
        {
          url,
          sha512,
        }:
        pkgs.fetchurl { inherit url sha512; };

      mods = {
        Lithium = mod {
          url = "https://cdn.modrinth.com/data/gvQqBUqZ/versions/UPNexAfy/lithium-fabric-0.25.2%2Bmc26.2.jar";
          sha512 = "db676376c05b7e912cdae5aad9e51f125adc1554ae2b204599ccb598751921aedbac98e97b9cba0333b6b52488c6b75c915a7dbd50436f97800387fe1aad1c50";
        };
        FerriteCore = mod {
          url = "https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar";
          sha512 = "d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584";
        };
        Krypton = mod {
          url = "https://cdn.modrinth.com/data/fQEb0iXm/versions/5WeL0Nkz/krypton-0.3.1.jar";
          sha512 = "b8d9af34cd0050493afb8a6232cb8f785daa9d8887b7045f6e6a53c6bb9b5ffc4318fd9b0347a940eacfeba4773f10cb80ae0be1e79ce4c1888f96eda21e564e";
        };

        Spark = mod {
          url = "https://cdn.modrinth.com/data/l6YH9Als/versions/iYFOl6lQ/spark-1.10.173-fabric.jar";
          sha512 = "1dcbf2b76ceacf07523afaeaf63d3625b0318077cc6ce588bb701aea4a494bc2a5179fd2ca5aeda9513c6a2248c2ec590387e8aec6ac9fd8e3d01760bbc3dbfb";
        };

        ServerCore = mod {
          url = "https://cdn.modrinth.com/data/4WWQxlQP/versions/edrtnY9v/servercore-fabric-1.5.19%2B26.2.jar";
          sha512 = "aa4cfc93f8e02172910302444330e37713dfcf2047d28e55eb7323a3cd5d51493374a0959aa3e626ec2bf43fc707a755508b83454bb34b6d57d65c069929074b";
        };
        Chunksmith = mod {
          url = "https://cdn.modrinth.com/data/4BeAEBIb/versions/StOy04qm/chunksmith-3.1.1%2B26.2.jar";
          sha512 = "b8bbcd54e064e6a1b33a5ae290077ccff79b5430624271772d82a368670b2474ce2f2c3cd95318778ee7b4c3e5fd5cbc511d43459bb7862c67668e4737cff8d7";
        };

        # Required at runtime by Chunksmith, ServerCore and Spark via
        # their own fabric.mod.json; removing it fails mod resolution.
        FabricAPI = mod {
          url = "https://cdn.modrinth.com/data/P7dR8mSH/versions/lVXlbH4w/fabric-api-0.155.2%2B26.2.jar";
          sha512 = "cc56984378a27c5bcd56374d6ffbb27a45c6bf3355add2ac6be9817ccac5854362249bf9d0147eb271a70fda2716129204e240d53c9aa876a2a7861f4c7f880f";
        };
      };

      # One self-contained jar, no Fabric and no mods, so it skips
      # mkServer. Compiled for Java 8, runs on jdk25.
      btaServer =
        let
          jar = pkgs.fetchurl {
            url = "https://downloads.betterthanadventure.net/bta-server/release/v8.0.1/bta.v8.0.1.server.jar";
            hash = "sha256-ihSLgO5x9UwyiloLnUhZ7W/1MQ0zF0BaFOdDV9qUAQY=";
          };
        in
        pkgs.writeShellScriptBin "minecraft-server" ''
          exec ${getExe' pkgs.jdk25_headless "java"} "$@" -jar ${jar} nogui
        '';

      mkServer = serverProperties: {
        enable = true;
        autoStart = true;

        package = serverPackage;

        jvmOpts = "-Xms2G -Xmx4G";

        symlinks.mods = pkgs.linkFarmFromDrvs "mods" (attrValues mods);

        # Chunksmith 3.x otherwise auto-enables an LOD store and a second
        # listener. `files`, not `symlinks`: the mod rewrites this config.
        files."config/chunksmith.json" = pkgs.writeText "chunksmith.json" (toJSON {
          lodEnabled = false;
        });

        serverProperties = {
          max-players = 5;
          difficulty = "normal";
          # A paused server ignores console input and stalls pregeneration.
          pause-when-empty-seconds = -1;
          online-mode = true;
          white-list = false;
          # ServerCore walks this down under load.
          view-distance = 20;
          # The firewall, not the bind address, keeps these tailnet-only.
          server-ip = "";
        }
        // serverProperties;
      };
    in
    {
      imports = singleton inputs.nix-minecraft.nixosModules.minecraft-servers;

      options.minecraft.enable = mkEnableOption "the declarative tailnet-only Fabric Minecraft server";

      config = mkIf cfg.enable {
        unfreePackages = singleton "minecraft-server";

        nixpkgs.overlays = singleton inputs.nix-minecraft.overlay;

        services.minecraft-servers = {
          enable = true;

          # systemd-socket rather than the default tmux, so output reaches
          # the journal. Console input: /run/minecraft-server/<name>.stdin.
          managementSystem.tmux.enable = false;
          managementSystem.systemd-socket.enable = true;

          eula = true;

          openFirewall = false;

          servers.main = mkServer {
            server-port = 25565;
            level-seed = "1133044835122437667"; # only consulted at world creation
            motd = "water // tailnet survival — stock clients welcome";
          };

          # Imported world: /srv/minecraft/serenity/world must be in place,
          # owned by minecraft, before first start or it is generated fresh.
          servers.serenity = mkServer {
            # Not 25566: Chunksmith's LOD listener squats on main's port+1.
            server-port = 25567;
            view-distance = 32;
            motd = "water // serenity — tailnet survival";
          };

          servers.bta = {
            enable = true;
            autoStart = true;
            package = btaServer;

            jvmOpts = "-Xms512M -Xmx2G";

            # Beta properties format: numeric difficulty (2 = normal), read
            # as latin-1 so the motd stays ASCII.
            serverProperties = {
              # Continues the scheme: odd ports serve, each even port above
              # belongs to that server's Chunksmith LOD listener.
              server-port = 25569;
              max-players = 5;
              difficulty = 2;
              online-mode = true;
              # BTA reads this fork-added key (default 10); 32 matches the
              # client slider's ceiling. Chunk work is on the main thread, so
              # walk it down if a full wander lags.
              view-distance = 32;
              motd = "water // better than adventure -- beta 1.7.3 continued";
              server-ip = "";
            };
          };
        };

        # nix-minecraft sandboxes these units; only the directives it
        # leaves out are added here, derived from the server list.
        systemd.services = mapAttrs' (name: _: {
          name = "minecraft-server-${name}";
          value.serviceConfig = {

            ProtectSystem = "strict";
            ReadWritePaths = [ "${dataDir}/${name}" ];
            NoNewPrivileges = true;
            # ProcSubset=pid is unset: it hides /proc/mounts, which Java's
            # NIO needs for file-store lookups, and world loading fails.
            RemoveIPC = true;
            UMask = lib.mkForce "0077"; # tighter than upstream's 0007

            # MemoryDenyWriteExecute is unset because the JVM JIT needs W+X.
            # Spark's async-profiler probes perf_event_open, outside
            # @system-service; EPERM makes that probe fail instead of
            # killing the JVM mid-startup.
            SystemCallFilter = [ "@system-service" ];
            SystemCallErrorNumber = "EPERM";

            # The internet is unmatched and so allowed, for session auth.
            IPAddressAllow = [
              "100.64.0.0/10" # tailnet (CGNAT range)
              "127.0.0.53/32" # resolved's stub, exempt from the deny below
            ];
            IPAddressDeny = [
              "127.0.0.0/8" # other loopback services
              "::1"
            ]
            ++ fences.privateRanges;
          };
        }) config.services.minecraft-servers.servers;
      };
    };
}
