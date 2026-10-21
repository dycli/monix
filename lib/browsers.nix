# The assistants' browsers on the host (assistant-browser.mod.nix) and the
# assistants that drive them agree on these.
{
  # The nth browser's loopback address, where its MCP server and VNC listen.
  addr = index: "127.0.1.${toString (30 + index)}";
  mcpPort = 8931;
  vncPort = 5900;
  # The nth screen page on the host's loopback, behind the proxy.
  screenPort = index: 6090 + index;
  # Square, for the most page per screenshot; 1920x1920 is still within the
  # model's image limit unscaled. Brave reports the smallest common screen
  # that holds the window (here 3840x2160), so the window never outsizes it.
  screen = "1920x1920";
  renderNode = "/dev/dri/renderD128";
}
