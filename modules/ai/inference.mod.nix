# llama.cpp served through llama-swap: one llama-server per model, spawned on
# demand and unloaded after `ttl` seconds idle, so an idle host holds no model
# RAM.
{ self, ... }:
{
  flake.nixosModules.inference =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets)
        listToAttrs
        mapAttrs
        mapAttrsToList
        nameValuePair
        ;
      inherit (lib.lists) concatLists singleton;
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkIf mkMerge;
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
          description = "where operator-supplied GGUF files live";
        };

        gttSizeMiB = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          description = "AMD GTT size in MiB; null leaves the kernel default";
        };

        extraAllowedSubnets = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "extra subnets permitted to reach llama-swap";
        };

        models = mkOption {
          default = { };
          description = ''
            The served catalog: attr name = the model id clients request
            (e.g. `local/qwen3.8-27b-q6-k` from opencode would name this
            "qwen3.8-27b-q6-k"). Each entry becomes a llama-swap model with a
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
                context = mkOption {
                  type = types.ints.positive;
                  default = 262144;
                  description = "total context window served by llama-server";
                };
                output = mkOption {
                  type = types.ints.positive;
                  default = 16384;
                  description = "maximum output OpenCode should reserve per response";
                };
                flags = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  example = [
                    "--flash-attn"
                    "on"
                  ];
                  description = "extra llama-server flags";
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

        openCodeModels = mkOption {
          type = types.attrsOf types.anything;
          readOnly = true;
          description = "OpenCode metadata for every served model id and alias";
        };
      };

      config = mkMerge [
        {
          inference.modelIds = concatLists (mapAttrsToList (name: m: singleton name ++ m.aliases) cfg.models);
          inference.openCodeModels =
            cfg.models
            |> mapAttrsToList (
              name: m:
              (singleton name ++ m.aliases)
              |> lib.lists.map (
                id:
                nameValuePair id {
                  name = id;
                  tool_call = true;
                  modalities = {
                    input = singleton "text";
                    output = singleton "text";
                  };
                  limit = {
                    inherit (m) context output;
                  };
                }
              )
            )
            |> concatLists
            |> listToAttrs;
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

              models =
                cfg.models
                |> mapAttrs (
                  _: m: {
                    # ${PORT} is llama-swap's macro, escaped so Nix passes it
                    # through verbatim.
                    cmd = concatStringsSep " " (
                      [
                        llamaServer
                        "--port \${PORT}"
                        "--host 127.0.0.1" # children speak only to the proxy
                        "-m ${if lib.strings.hasPrefix "/" m.file then m.file else "${cfg.modelsDir}/${m.file}"}"
                        "-ngl 999" # full offload; unified memory has no VRAM cliff
                        "-c ${toString m.context}"
                        "--no-webui"
                      ]
                      ++ m.flags
                    );
                    inherit (m) ttl aliases;
                  }
                );
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
            DeviceAllow = singleton "char-drm rw";

            # Child servers use loopback; clients use the tailnet plus any
            # role-specific private subnet. No public internet.
            IPAddressAllow = fences.loopback ++ singleton fences.tailnet ++ cfg.extraAllowedSubnets;
            IPAddressDeny = "any";
          };

          # World-readable so the DynamicUser service can read the models;
          # group write is scoped to `models`, not all of `users`.
          users.groups.models = { };
          systemd.tmpfiles.rules = singleton "d ${cfg.modelsDir} 0775 ${config.primaryUser} models -";

          environment.systemPackages = singleton llamaCpp;
        }

        (mkIf (cfg.gttSizeMiB != null) {
          # Unified-memory GPUs map model weights through GTT. GTT is a limit,
          # not a reservation; the TTM page limits use 4 KiB pages.
          boot.kernelParams = [
            "amdgpu.gttsize=${toString cfg.gttSizeMiB}"
            "ttm.pages_limit=${toString (cfg.gttSizeMiB * 256)}"
            "ttm.page_pool_size=${toString (cfg.gttSizeMiB * 256)}"
          ];
        })
      ];
    };
}
