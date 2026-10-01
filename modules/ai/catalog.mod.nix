# Every model the fleet serves, per host, plus the OpenCode client view of
# the same catalog. Model weights stay with the importing host.
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
  flake.nixosModules.inference-radeon-24gb =
    { ... }:
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
      imports = [ self.nixosModules.inference ];

      inference.models = {
        "qwen3.8-27b-q4-k-m" = qwen38 147456 "Qwen3.8-27B-Q4_K_M.gguf";
        "qwen3.8-27b-q5-k-s" = qwen38 98304 "Qwen3.8-27B-Q5_K_S.gguf";
      };
    };

  flake.homeModules.inference-client =
    { lib, osConfig, ... }:
    let
      inherit (lib.ship) opencode;
      inherit (lib.strings) toJSON;
    in
    {
      home.sessionVariables = opencode.environment;

      home.file.".config/opencode/opencode.jsonc" = {
        force = true;
        text = toJSON {
          "$schema" = "https://opencode.ai/config.json";
          inherit (opencode) lsp mcp;
          permission = opencode.permissions;
          provider.local = {
            npm = "@ai-sdk/openai-compatible";
            name = "${osConfig.networking.hostName} local inference";
            options = {
              baseURL = "http://127.0.0.1:${toString osConfig.inference.port}/v1";
              apiKey = "local";
            };
            models = osConfig.inference.openCodeModels;
          };
        };
      };
    };
}
