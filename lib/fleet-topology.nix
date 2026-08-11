{
  bridge = "br-agents";
  hostAddr = "10.100.0.1";
  tasksDir = "/var/lib/agents/tasks";
  readersGroup = "agent-fleet-readers";

  hostTailnetAddr = "100.102.113.74";
  hostMagicDnsName = "water.olm-hen.ts.net";

  # Off 127.0.0.1, which other services' fences already admit.
  seatWebAddr = "127.0.1.10";
  seatWebPort = 4097;

  # Source address nginx proxies from (proxy_bind), so the seat's fence
  # admits nginx alone.
  seatIngressAddr = "127.0.1.11";

  # Address the seat dials llama-swap on; llama-swap binds the wildcard, so
  # no listener of its own is needed here.
  seatInferenceAddr = "127.0.1.12";
}
