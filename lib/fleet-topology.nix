{
  bridge = "br-agents";
  hostAddr = "10.100.0.1";
  tasksDir = "/var/lib/agents/tasks";
  readersGroup = "agent-fleet-readers";

  # Carries the task exchange across virtiofs; the gid is pinned so host
  # and guest agree on it.
  guestGroup = "agent-guest";
  guestGid = 3000;

  hostTailnetAddr = "100.102.113.74";
  hostMagicDnsName = "water.olm-hen.ts.net";

  # Address the seat dials llama-swap on; llama-swap binds the wildcard, so
  # no listener of its own is needed here.
  seatInferenceAddr = "127.0.1.12";
}
