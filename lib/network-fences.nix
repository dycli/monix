{
  # The ordinary loopback plane, and the ONLY loopback a fenced service
  # may reach. Every ship service listens on 127.0.0.1; resolved's stubs
  # are 127.0.0.53/.54. The AI seat deliberately listens OUTSIDE this /24
  # — squid on 127.0.1.9, the web seat on 127.0.1.10 (fleet-topology.nix)
  # — so a service that legitimately needs loopback still cannot reach the
  # seat and drive the agent behind it.
  #
  # Use this instead of hand-rolling "127.0.0.0/8": systemd checks
  # IPAddressAllow FIRST and a match GRANTS access outright (see
  # systemd.resource-control(5)), so a blanket loopback allow silently
  # re-opens the seat no matter what the deny list says.
  loopback = [
    "127.0.0.0/24"
    "::1"
  ];

  privateRanges = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "fc00::/7"
    "fe80::/10"
  ];

  internetOnlyDeny = [
    "link-local"
    "multicast"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "100.64.0.0/10"
    "fc00::/7"
    "fe80::/10"
  ];
}
