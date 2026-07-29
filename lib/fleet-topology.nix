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

  # The web seat's listener (opencode-web in cockpit.mod.nix). Its own
  # loopback address, NOT 127.0.0.1: the untrusted-input parser fences
  # (media/immich/frigate) allow 127.0.0.1/32 for inter-service APIs, and
  # keeping the seat off that address is what makes it unreachable from a
  # compromised parser. nginx (ship-proxy) is the only intended client.
  seatWebAddr = "127.0.1.10";
  seatWebPort = 4097;
}
