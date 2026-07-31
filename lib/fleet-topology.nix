{
  bridge = "br-agents";
  hostAddr = "10.100.0.1";
  tasksDir = "/var/lib/agents/tasks";
  readersGroup = "agent-fleet-readers";

  # squid's listener for the seat; the slice fence in cockpit.mod.nix
  # allows exactly this address.
  seatProxyAddr = "127.0.1.9";
  seatProxyPort = 3129;

  # opencode-web listens here rather than on 127.0.0.1, which the parser
  # fences allow for inter-service APIs.
  seatWebAddr = "127.0.1.10";
  seatWebPort = 4097;

  # Source address nginx proxies from (ship-proxy.mod.nix sets
  # proxy_bind), so the seat's fence can admit nginx without admitting
  # everything else on 127.0.0.1.
  seatIngressAddr = "127.0.1.11";

  # Address the seat dials llama-swap on (it binds the wildcard, so this
  # needs no listener of its own). A dedicated address so the seat fences
  # can admit inference without admitting everything else on 127.0.0.1.
  seatInferenceAddr = "127.0.1.12";
}
