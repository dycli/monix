# The assistants' code runners (yeoman-computer.mod.nix), their own network
# (yeoman-network.mod.nix) and the assistant that drives them
# (yeoman.mod.nix) agree on these.
lib:
let
  inherit (lib.attrsets)
    attrNames
    filterAttrs
    listToAttrs
    nameValuePair
    ;
  inherit (lib.lists) imap1;
in
{
  bridge = "br-pcs";
  hostAddr = "10.101.0.1";
  subnet = "10.101.0.0/24";
  # The nth computer, from 1.
  addr = index: "10.101.0.${toString (10 + index)}";
  # Each owner's index, by sorted instance name; a rename costs the
  # computer nothing but its address.
  indexes =
    instances:
    filterAttrs (_: i: i.computer) instances
    |> attrNames
    |> imap1 (i: n: nameValuePair n i)
    |> listToAttrs;
  # Public resolvers: the guest is internet-only and must not depend on
  # the host's.
  nameservers = [
    "9.9.9.9"
    "1.1.1.1"
  ];

  # The runner of the assistant's code (yeoman-computer/runner.py).
  runPort = 8934;

  # Each assistant's desk, shared with its runner.
  desks = "/var/lib/yeoman-desks";
  deskMount = "/desk";
  # The desk's folder of runs, one folder each, made by the host.
  runs = "runs";
  deskGroup = "yeoman-desk";
  deskGid = 3001;
}
