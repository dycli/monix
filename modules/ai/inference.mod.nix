# llama.cpp served through llama-swap: one llama-server per model, spawned on
# demand and unloaded after `ttl` seconds idle, so an idle host holds no model
# RAM. Each GPU class has its catalog aspect; model weights stay with the
# importing host.
{ self, ... }:
let
  baseFlags = [
    "--flash-attn"
    "on"
    "--jinja"
  ];

  # MTP speculative decoding: the MTP tensors are embedded in the main GGUF,
  # so --spec-type selects that path with no separate draft model. -np > 1 is
  # unsupported with MTP.
  mtpFlags = [
    "--spec-type"
    "draft-mtp"
    "--spec-draft-n-max"
    "2"
    "-np"
    "1"
  ];
in
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
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatStringsSep;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.inference;

      modelsDir = "/var/lib/models";

      llamaCpp = pkgs.llama-cpp.override { vulkanSupport = true; };
      llamaServer = getExe' llamaCpp "llama-server";
    in
    {
      options.inference = {
        port = mkOption {
          type = types.port;
          default = 8091;
          description = ''
            llama-swap's OpenAI-compatible endpoint. Not 8080, which SABnzbd
            holds.
          '';
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
            /var/lib/models, add an entry, switch.
          '';
          type = types.attrsOf (
            types.submodule {
              options = {
                file = mkOption {
                  type = types.str;
                  description = "GGUF filename relative to /var/lib/models (or an absolute path)";
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

        openCodeModels = mkOption {
          type = types.attrsOf types.anything;
          readOnly = true;
          description = "OpenCode metadata for every served model id and alias";
        };
      };

      config = {
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

        services.llama-swap = {
          enable = true;
          # The firewall handles reachability.
          listenAddress = "0.0.0.0";
          inherit (cfg) port;
          openFirewall = false;

          settings = {
            # A cold model can take longer to load than the 120s default
            # health check allows.
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
                      "-m ${if lib.strings.hasPrefix "/" m.file then m.file else "${modelsDir}/${m.file}"}"
                      "-ngl 999" # full offload
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
        systemd.tmpfiles.rules = singleton "d ${modelsDir} 0775 ${config.primaryUser} models -";

        environment.systemPackages = singleton llamaCpp;
      };
    };

  flake.nixosModules.inference-radeon-24gb =
    { lib, ... }:
    let
      # qwen3.8 is hybrid SSM/attention (full attention every 4th layer), so
      # even long contexts fit a 24G card; q8 KV halves what remains. Q4 takes
      # 144K, while Q5 trades some context for higher weight precision at 96K.
      qwen38 = context: file: {
        inherit context file;
        output = 8192;
        flags =
          baseFlags
          ++ [
            "--cache-type-k"
            "q8_0"
            "--cache-type-v"
            "q8_0"
          ]
          ++ mtpFlags;
      };
    in
    {
      imports = lib.lists.singleton self.nixosModules.inference;

      inference.models = {
        "qwen3.8-27b-q4-k-m" = qwen38 147456 "Qwen3.8-27B-Q4_K_M.gguf";
        "qwen3.8-27b-q5-k-s" = qwen38 98304 "Qwen3.8-27B-Q5_K_S.gguf";
      };
    };

  # The OpenCode client view of this host's catalog.
  flake.homeModules.inference-client =
    { lib, osConfig, ... }:
    let
      inherit (lib.ship) opencode;
    in
    {
      home.sessionVariables = opencode.environment;

      home.file.".config/opencode/opencode.jsonc" = {
        force = true;
        text = lib.strings.toJSON (
          opencode.config {
            name = "${osConfig.networking.hostName} local inference";
            baseURL = "http://127.0.0.1:${toString osConfig.inference.port}/v1";
            models = osConfig.inference.openCodeModels;
          }
        );
      };
    };
}
