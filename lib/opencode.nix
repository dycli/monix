_: {
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
}
