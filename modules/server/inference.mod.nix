# llama.cpp served through llama-swap, which spawns and kills one
# llama-server per model on demand and unloads after `ttl` seconds idle,
# so an idle host holds no model RAM and only one model runs at a time.
#
# Built with Vulkan, since RADV is the mature path on gfx1151, and models
# fully offload with -ngl 999. The iGPU maps weights from system RAM via
# GTT, whose kernel default of about half of RAM caps models near 60G on
# this box; the ttm and amdgpu parameters below raise it and take effect
# on the next reboot.
#
# The egress fence allows only loopback and the tailnet, which also blocks
# llama-server's own -hf downloads; models are fetched by hand into
# `inference.modelsDir`.
{
  flake.nixosModules.inference =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) mapAttrs;
      inherit (lib.lists) optionals singleton;
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib.strings) concatStringsSep;
      inherit (lib) types;
      networkFences = import ../../lib/network-fences.nix;

      cfg = config.inference;

      llamaCpp = pkgs.llama-cpp.override { vulkanSupport = true; };
      llamaServer = getExe' llamaCpp "llama-server";
    in
    {
      options.inference = {
        enable = mkEnableOption "the tailnet-only llama.cpp/llama-swap local inference server";

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
            Where GGUF files live (on fw0 the @models btrfs subvolume). The
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
      };

      config = mkIf cfg.enable {
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

            models = mapAttrs (name: m: {
              # llama-swap's macro for a fresh port per spawn, escaped so
              # Nix passes it through verbatim.
              cmd = concatStringsSep " " (
                [
                  llamaServer
                  "--port \${PORT}"
                  "--host 127.0.0.1" # children speak only to the proxy
                  "-m ${if lib.strings.hasPrefix "/" m.file then m.file else "${cfg.modelsDir}/${m.file}"}"
                  "-ngl 999" # full iGPU offload — unified memory, no VRAM cliff
                  "--no-webui" # llama-swap's own UI serves the humans
                ]
                ++ m.flags
              );
              inherit (m) ttl aliases;
            }) cfg.models;
          };
        };

        systemd.services.llama-swap.serviceConfig = {

          # Upstream leaves PrivateDevices false but grants no device
          # class; this opens the DRM render path Vulkan needs.
          SupplementaryGroups = [
            "render"
            "video"
          ];
          DevicePolicy = "closed";
          DeviceAllow = [ "char-drm rw" ];

          # Loopback for the spawned llama-servers, the tailnet, and the
          # guest bridge when the fleet runs here. No public internet.
          IPAddressAllow =
            networkFences.loopback
            ++ [
              "100.64.0.0/10" # tailnet (CGNAT range)
            ]
            ++ optionals config.agentFleet.enable [
              "10.100.0.0/24" # the br-agents guest subnet (see microvm-host.mod.nix)
            ];
          IPAddressDeny = "any";
        };

        # GTT is a limit rather than a reservation, so an idle host pays
        # nothing. 96G expressed as 98304 MiB and 25165824 4K pages;
        # page_pool_size bounds TTM's cached-page reuse pool to match.
        boot.kernelParams = [
          "amdgpu.gttsize=98304"
          "ttm.pages_limit=25165824"
          "ttm.page_pool_size=25165824"
        ];

        # Downloads happen as the primary user; world-readable so the
        # DynamicUser service can read them.
        systemd.tmpfiles.rules = singleton "d ${cfg.modelsDir} 0755 ${config.primaryUser} users -";

        # llama-cli, llama-bench and friends, for work outside the service.
        environment.systemPackages = singleton llamaCpp;
      };
    };
}
