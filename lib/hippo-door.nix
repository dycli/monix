# A hippo door (`hippo door`): one memory, read-only, as a remote MCP server
# on loopback, for the hippo tunnel to carry out. Each memory has its own
# door, passphrase and signed-in apps; a door reads only its own store.
lib:
{
  # The hippo package, its memory's service unit, and the store it serves.
  hippo,
  service,
  dir,
  # The store's owner, whom the door runs as.
  user,
  agent,
  person,
  port,
  host,
  passphraseFile,
}:
let
  inherit (lib.lists) singleton;
  inherit (lib.ship) fences;
in
{
  description = "${agent}'s memory as a remote MCP server";
  wantedBy = singleton "multi-user.target";
  after = singleton service;
  unitConfig.RequiresMountsFor = singleton dir;
  environment = {
    HIPPO_DIR = dir;
    HIPPO_AGENT = agent;
    HIPPO_PERSON = person;
  };
  serviceConfig = lib.ship.hardened.tenant // {
    User = user;
    Group = user;
    ExecStart = "${lib.meta.getExe hippo} door 127.0.0.1:${toString port} https://${host}";
    LoadCredential = singleton "passphrase:${passphraseFile}";
    # Registered apps and token hashes.
    StateDirectory = "hippo-door-${user}";
    Restart = "always";
    RestartSec = 5;
    # A socket on a read-only path still connects; the store stays
    # read-only to the door.
    ReadOnlyPaths = singleton dir;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
    ];
    SocketBindAllow = singleton "tcp:${toString port}";
    IPAddressAllow = fences.loopback;
    IPAddressDeny = "any";
  };
}
