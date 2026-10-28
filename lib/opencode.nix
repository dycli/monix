lib:
let
  environment = {
    OPENCODE_DISABLE_LSP_DOWNLOAD = "true";
    OPENCODE_ENABLE_EXA = "1";
    OPENCODE_EXPERIMENTAL_LSP_TOOL = "true";
  };

  lsp = {
    nixd.command = [ "nixd" ];
    rust.command = [ "rust-analyzer" ];
  };

  mcp.context7 = {
    type = "remote";
    url = "https://mcp.context7.com/mcp";
    enabled = true;
  };

  permissions = {
    "context7_*" = "allow";
    lsp = "allow";
    websearch = "allow";
  };
  # The cloud providers on the host's keys. Zen and Go share one key,
  # read from keyFile at each start so a rotated secret needs no
  # activation (OpenCode 2 ignores auth.json). DeepSeek and abliteration.ai
  # read their own key files the same way.
  providers =
    {
      keyFile,
      deepseekKeyFile,
      abliterationKeyFile,
    }:
    {
      opencode.options.apiKey = "{file:${keyFile}}";
      opencode-go.options.apiKey = "{file:${keyFile}}";
      deepseek.options.apiKey = "{file:${deepseekKeyFile}}";
      # Not in OpenCode's catalog, so declared in full.
      abliteration = {
        npm = "@ai-sdk/openai-compatible";
        name = "abliteration.ai";
        models.abliterated-model.name = "Abliterated";
        options = {
          baseURL = "https://api.abliteration.ai/v1";
          apiKey = "{file:${abliterationKeyFile}}";
        };
      };
    };
in
{
  inherit environment permissions providers;

  # omp's models.yml: its built-in providers on the keys OpenCode uses. A
  # leading `!` makes omp read the key from the command's output at
  # request time, so no key enters the Nix store and a rotated secret
  # needs no activation. JSON is valid YAML.
  ompModels =
    {
      keyFile,
      deepseekKeyFile,
      abliterationKeyFile,
    }:
    let
      keyFrom = file: { apiKey = "!cat ${file}"; };
    in
    lib.strings.toJSON {
      providers = {
        deepseek = keyFrom deepseekKeyFile;
        abliteration = keyFrom abliterationKeyFile;
        opencode-zen = keyFrom keyFile;
        opencode-go = keyFrom keyFile;
      };
    };

  # An opencode.json whose `local` provider is a llama-swap endpoint, beside
  # the cloud providers. The ai-sdk loader requires a non-empty apiKey;
  # llama-swap ignores it. The shared permissions win over the caller's.
  config =
    {
      name,
      baseURL,
      models,
      keyFile,
      deepseekKeyFile,
      abliterationKeyFile,
      extraMcp ? { },
      permission ? { },
      agent ? { },
    }:
    {
      "$schema" = "https://opencode.ai/config.json";
      inherit lsp;
      mcp = mcp // extraMcp;
      permission = permission // permissions;
      provider = providers { inherit keyFile deepseekKeyFile abliterationKeyFile; } // {
        local = {
          npm = "@ai-sdk/openai-compatible";
          inherit name models;
          options = {
            inherit baseURL;
            apiKey = "local";
          };
        };
      };
    }
    // lib.attrsets.optionalAttrs (agent != { }) { inherit agent; };
}
