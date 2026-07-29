{
  bridge = "br-agents";
  hostAddr = "10.100.0.1";
  tasksDir = "/var/lib/agents/tasks";
  readersGroup = "agent-fleet-readers";

  # The bridge seat's egress door: squid's dedicated loopback listener.
  # The slice fence (cockpit.mod.nix) allows exactly seatProxyAddr; the
  # listener and proxy env derive from the same pair.
  seatProxyAddr = "127.0.1.9";
  seatProxyPort = 3129;
}
