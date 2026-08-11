# llama.cpp served through llama-swap: one llama-server per model, spawned on
# demand and unloaded after `ttl` seconds idle, so an idle host holds no model
# RAM.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.inference;
  flake.nixosModules.inference =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) mapAttrs mapAttrsToList;
      inherit (lib.lists) concatLists singleton;
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkMerge;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatStringsSep;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.inference;

      # Vulkan, not ROCm: RADV is the mature path on gfx1151.
      llamaCpp = pkgs.llama-cpp.override { vulkanSupport = true; };
      llamaServer = getExe' llamaCpp "llama-server";
    in
    {
      options.inference = {
        port = mkOption {
          type = types.port;
          default = 8091;
          description = ''
            llama-swap's OpenAI-compatible endpoint. Not 8080: Open WebUI's
            default, kept clash-free for when the gateway stack is enabled.
          '';
        };

        modelsDir = mkOption {
          type = types.str;
          default = "/var/lib/models";
          description = ''
            Where GGUF files live (on water the @models btrfs subvolume). The
            operator downloads into it (owned by the primary user); the
            service only ever reads it.
          '';
        };

        models = mkOption {
          default = { };
          description = ''
            The served catalog: attr name = the model id clients request
            (e.g. `local/qwen3.6-27b` from opencode would name this
            "qwen3.6-27b"). Each entry becomes a llama-swap model with a
            generated llama-server cmd. Adding a model = drop the GGUF in
            modelsDir, add an entry, switch.
          '';
          type = types.attrsOf (
            types.submodule {
              options = {
                file = mkOption {
                  type = types.str;
                  description = "GGUF filename relative to modelsDir (or an absolute path)";
                };
                flags = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  example = [
                    "-c"
                    "32768"
                  ];
                  description = "extra llama-server flags (context size, jinja templates, ...)";
                };
                ttl = mkOption {
                  type = types.int;
                  default = 600;
                  description = "seconds idle before llama-swap unloads the model";
                };
                aliases = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "extra model ids that resolve to this entry";
                };
              };
            }
          );
        };

        modelIds = mkOption {
          type = types.listOf types.str;
          readOnly = true;
          description = ''
            Every id the catalog answers to — model names plus aliases.
            Derived from `models`; consumers generating client
            configuration read this instead of re-deriving it.
          '';
        };
      };

      config = mkMerge [
        {
          inference.modelIds = concatLists (mapAttrsToList (name: m: [ name ] ++ m.aliases) cfg.models);
        }

        {
          services.llama-swap = {
            enable = true;
            # The firewall handles reachability.
            listenAddress = "0.0.0.0";
            inherit (cfg) port;
            openFirewall = false;

            settings = {
              # A cold 60G model takes minutes to load from NVMe into GTT,
              # longer than the 120s default health check allows.
              healthCheckTimeout = 600;

              models = mapAttrs (_: m: {
                # ${PORT} is llama-swap's macro, escaped so Nix passes it
                # through verbatim.
                cmd = concatStringsSep " " (
                  [
                    llamaServer
                    "--port \${PORT}"
                    "--host 127.0.0.1" # children speak only to the proxy
                    "-m ${if lib.strings.hasPrefix "/" m.file then m.file else "${cfg.modelsDir}/${m.file}"}"
                    "-ngl 999" # full offload; unified memory has no VRAM cliff
                    "--no-webui"
                  ]
                  ++ m.flags
                );
                inherit (m) ttl aliases;
              }) cfg.models;
            };
          };

          systemd.services.llama-swap.serviceConfig = {

            # Upstream leaves PrivateDevices false but grants no device class;
            # this opens the DRM render path Vulkan needs.
            SupplementaryGroups = [
              "render"
              "video"
            ];
            DevicePolicy = "closed";
            DeviceAllow = [ "char-drm rw" ];

            # Loopback for the spawned llama-servers, the tailnet, and the
            # guest bridge when the fleet runs here. No public internet.
            IPAddressAllow = fences.loopback ++ [
              fences.tailnet
              "10.100.0.0/24" # br-agents guest subnet
            ];
            IPAddressDeny = "any";
          };

          # The iGPU maps weights from system RAM through GTT, whose kernel
          # default of about half of RAM caps model size. GTT is a limit, not a
          # reservation, so an idle host pays nothing. 96G as 98304 MiB and
          # 25165824 4K pages; page_pool_size bounds TTM's reuse pool to match.
          boot.kernelParams = [
            "amdgpu.gttsize=98304"
            "ttm.pages_limit=25165824"
            "ttm.page_pool_size=25165824"
          ];

          # World-readable so the DynamicUser service can read the models;
          # group write is scoped to `models` (the seat), not all of `users`.
          users.groups.models = { };
          systemd.tmpfiles.rules = singleton "d ${cfg.modelsDir} 0775 ${config.primaryUser} models -";

          environment.systemPackages = singleton llamaCpp;
        }
      ];
    };
}
