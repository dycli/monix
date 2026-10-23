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
                tools = mkOption {
                  type = types.bool;
                  default = true;
                  description = "whether the model can call tools; OpenCode sends none when false";
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
                tool_call = m.tools;
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

        # `hf download` fetches GGUFs into the models directory; hf_xet makes
        # it pull chunks in parallel.
        environment.systemPackages = [
          llamaCpp
          (pkgs.python3.withPackages (
            ps: singleton ps.huggingface-hub ++ ps.huggingface-hub.optional-dependencies.hf_xet
          ))
        ];
      };
    };

  flake.nixosModules.inference-radeon-24gb =
    { lib, ... }:
    let
      # qwen3.8 is hybrid SSM/attention (full attention every 4th layer), so
      # even long contexts fit a 24G card; q8 KV halves what remains, so Q4
      # takes 144K. Unsloth's UD-Q4_K_XL measured a hair better than plain Q4_K_M
      # at the same size and speed.
      qwen38 = context: file: {
        inherit context file;
        output = 8192;
        flags =
          baseFlags
          ++ [
            # The GGUFs' own template raises on any system message after the
            # first, which OpenCode sends; this copy renders it as a system
            # turn instead. Drop it once the upstream template accepts them.
            "--chat-template-file"
            "${./qwen38.jinja}"
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
        "qwen3.8-27b-ud-q4-k-xl" = qwen38 147456 "Qwen3.8-27B-UD-Q4_K_XL.gguf";
        # orcarouter's uncensored fine-tune, pulled from Ollama's registry
        # (registry.ollama.ai/v2/orcarouter/qwen3.8-27b-uncensored/blobs/…),
        # which serves the same GGUF without Hugging Face's sign-in gate.
        "qwen3.8-27b-uncensored-q4-k-m" = qwen38 147456 "Qwen3.8-27B-Uncensored-Q4_K_M.gguf";
        # talkie: a 13B trained only on pre-1931 text. zakarth's GGUF rescales
        # two layer-14 ffn_down channels (bit-exact) whose activations overflow
        # fp16 in llama.cpp's Vulkan matmul (ggml-org/llama.cpp#23953) and
        # turn the plain GGUFs to garbage; move to an unmodified GGUF once
        # Vulkan keeps those activations in bf16. Trained at 2048 context.
        "talkie-1930-13b-q8-0" = {
          file = "talkie-1930-13b-it.Q8_0.gguf";
          context = 2048;
          output = 1024;
          flags = baseFlags;
          aliases = [ "talkie" ];
          tools = false;
        };
      };
    };

  # The OpenCode client view of this host's catalog.
  flake.homeModules.inference-client =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.ship) opencode;
      baseURL = "http://127.0.0.1:${toString osConfig.inference.port}/v1";
      talkie = osConfig.inference.models."talkie-1930-13b-q8-0" or null;
    in
    {
      home.sessionVariables = opencode.environment;

      # `talkie` opens OpenCode on the 1930 model alone. Its 2048-token window
      # can't hold OpenCode's coding prompt, tool schemas or the global
      # AGENTS.md (~1k tokens), so it gets its own config home holding only a
      # one-line prompt, and runs outside any repository so no project
      # AGENTS.md loads either.
      home.file.".local/state/talkie/opencode/opencode.jsonc" = lib.mkIf (talkie != null) {
        text = lib.strings.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          autoupdate = false;
          model = "local/talkie";
          small_model = "local/talkie";
          default_agent = "talkie";
          permission."*" = "deny";
          provider.local = {
            npm = "@ai-sdk/openai-compatible";
            name = "talkie";
            models.talkie = osConfig.inference.openCodeModels.talkie;
            options = {
              inherit baseURL;
              apiKey = "local";
            };
          };
          agent.talkie = {
            mode = "primary";
            model = "local/talkie";
            prompt = "You are talkie, a conversationalist who knows only what was written before 1931. Answer plainly and briefly.";
          };
        };
      };
      home.packages = lib.optional (talkie != null) (
        pkgs.writeShellScriptBin "talkie" ''
          export XDG_CONFIG_HOME="$HOME/.local/state/talkie"
          export OPENCODE_DISABLE_CLAUDE_CODE=1
          cd "$XDG_CONFIG_HOME"
          exec opencode "$@"
        ''
      );

      home.file.".config/opencode/opencode.jsonc" = {
        force = true;
        text = lib.strings.toJSON (
          opencode.config {
            name = "${osConfig.networking.hostName} local inference";
            inherit baseURL;
            models = osConfig.inference.openCodeModels;
          }
        );
      };
    };
}
