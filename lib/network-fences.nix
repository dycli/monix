{
  # Services listen on 127.0.0.1 and resolved's stubs are 127.0.0.53/.54; the
  # AI seat listens outside this /24 (fleet-topology.nix). Not 127.0.0.0/8:
  # systemd checks IPAddressAllow before IPAddressDeny and a match in Allow
  # grants outright, so a blanket loopback allow overrides the deny list.
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
