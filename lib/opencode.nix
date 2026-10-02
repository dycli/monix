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
in
{
  inherit environment permissions;

  # An opencode.json whose `local` provider is a llama-swap endpoint. The
  # ai-sdk loader requires a non-empty apiKey; llama-swap ignores it. The
  # shared permissions win over the caller's.
  config =
    {
      name,
      baseURL,
      models,
      extraMcp ? { },
      permission ? { },
      agent ? { },
    }:
    {
      "$schema" = "https://opencode.ai/config.json";
      inherit lsp;
      mcp = mcp // extraMcp;
      permission = permission // permissions;
      provider.local = {
        npm = "@ai-sdk/openai-compatible";
        inherit name models;
        options = {
          inherit baseURL;
          apiKey = "local";
        };
      };
    }
    // lib.attrsets.optionalAttrs (agent != { }) { inherit agent; };
}
