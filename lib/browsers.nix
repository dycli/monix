# The assistants' browsers on the host (assistant-browser.mod.nix) and the
# assistants that drive them agree on these.
{
  # The nth browser's loopback address, where its MCP server and VNC listen.
  addr = index: "127.0.1.${toString (30 + index)}";
  mcpPort = 8931;
  vncPort = 5900;
  # The nth screen page on the host's loopback, behind the proxy.
  screenPort = index: 6090 + index;
  # 4:3, the tallest landscape shape: the most page per screenshot while a
  # 1920-wide capture still scales down legibly for the model.
  screen = "1920x1440";
  renderNode = "/dev/dri/renderD128";
}
