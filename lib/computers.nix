# The assistants' computers (sokka-computer.mod.nix), their own network
# (sokka-network.mod.nix) and the assistant that drives them
# (sokka.mod.nix) agree on these.
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

  mcpPort = 8931;
  vncPort = 5900;
  # The nth screen on the host's loopback, for the person's browser.
  screenPort = index: 6080 + index;
  screen = "1280x720";

  # Each assistant's desk: screenshots and downloads out, uploads in.
  desks = "/var/lib/sokka-desks";
  deskMount = "/desk";
  deskGroup = "sokka-desk";
  deskGid = 3001;
}
