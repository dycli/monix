# The assistants' code runners (assistant-computer.mod.nix), their own network
# (assistant-network.mod.nix) and the assistant that drives them
# (libri.mod.nix) agree on these.
lib:
let
  inherit (lib.attrsets) listToAttrs nameValuePair;
  inherit (lib.lists) imap1 singleton;
in
{
  bridge = "br-pcs";
  hostAddr = "10.101.0.1";
  subnet = "10.101.0.0/24";
  # The nth computer, from 1.
  addr = index: "10.101.0.${toString (10 + index)}";
  # Each owner's index, from 1; a rename costs the computer nothing but its
  # address.
  indexes = imap1 (i: n: nameValuePair n i) (singleton "suki") |> listToAttrs;
  # Public resolvers: the guest is internet-only and must not depend on
  # the host's.
  nameservers = [
    "9.9.9.9"
    "1.1.1.1"
  ];

  # The runner of the assistant's code (assistant-computer/runner.py).
  runPort = 8934;

  # Each assistant's desk, shared with its runner.
  desks = "/var/lib/assistant-desks";
  deskMount = "/desk";
  # The desk's folder of runs, one folder each, made by the host.
  runs = "runs";
  deskGroup = "assistant-desk";
  deskGid = 3001;
}
