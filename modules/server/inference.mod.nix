# Local-inference aspect — llama.cpp served through llama-swap on
# `inference.port`. Inert until a host sets `inference.enable`.
#
# llama-swap spawns/kills a llama-server per model on demand from
# `inference.models` and unloads after `ttl` seconds idle, so an idle box
# holds ~0 model RAM; only one model is active at a time. The fleet-wide
# ceiling is llama-swap's own budget below; the host sets no cgroup cap.
#
# Tuned for fw0's Strix Halo iGPU: built with Vulkan (RADV is the mature
# path on gfx1151; ROCm support there is younger), models fully offload
# via -ngl 999. The iGPU maps weights out of system RAM via GTT, whose
# kernel default (~half of RAM) caps models at ~60G on a 128G box; the
# ttm/amdgpu kernel params below raise it to match the slice fence and
# take effect only on the next reboot.
#
# The server parses untrusted prompts (tailnet, and fleet guests if
# wired), so assume compromise: upstream's sandbox is tightened with a
# GPU device grant and an egress fence
# allowing only loopback + tailnet — no public internet, no LAN, no fleet
# bridge. This also blocks llama-server's own -hf downloading; models are
# fetched by the operator into `inference.modelsDir`.
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
            (e.g. `local/gpt-oss-120b` from opencode would name this
            "gpt-oss-120b"). Each entry becomes a llama-swap model with a
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
          # Bind everywhere; reachability is the firewall's job — tailnet-
          # only until a bridge pinhole is opened for the guests.
          listenAddress = "0.0.0.0";
          inherit (cfg) port;
          openFirewall = false;

          settings = {
            # A cold 60G model is minutes of NVMe -> GTT load; don't let
            # the health check give up mid-load (default 120s).
            healthCheckTimeout = 600;

            models = mapAttrs (name: m: {
              # ''${PORT} is llama-swap's macro (a fresh port per spawn),
              # escaped so Nix passes it through verbatim.
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
          # Count model RAM against the host's inference fence, not the
          # default system slice.

          # Upstream leaves PrivateDevices=false but grants no device
          # class; open exactly the DRM render path Vulkan needs.
          SupplementaryGroups = [
            "render"
            "video"
          ];
          DevicePolicy = "closed";
          DeviceAllow = [ "char-drm rw" ];

          # No public internet. Loopback (llama-swap -> spawned
          # llama-servers), the tailnet, and (if this host also runs the
          # agent fleet) the guest bridge subnet, so drones can reach local
          # models via the br-agents pinhole. Deny everything else.
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

        # GTT is a limit, not a reservation — an idle box pays nothing.
        # 96G of the host's 128G left for models: 98304 MiB / 25165824
        # 4K pages. page_pool_size caps TTM's cached-page reuse pool at the
        # same bound.
        boot.kernelParams = [
          "amdgpu.gttsize=98304"
          "ttm.pages_limit=25165824"
          "ttm.page_pool_size=25165824"
        ];

        # Operator-owned (downloads happen as the primary user), world-
        # readable for the DynamicUser service.
        systemd.tmpfiles.rules = singleton "d ${cfg.modelsDir} 0755 ${config.primaryUser} users -";

        # llama-cli / llama-bench / llama-gguf etc. for pulling, inspecting,
        # and benchmarking models outside the service sandbox.
        environment.systemPackages = singleton llamaCpp;
      };
    };
}
