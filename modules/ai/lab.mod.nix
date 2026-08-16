# The lab role's instance settings: the knobs for the bundle the other
# modules in this directory assemble by registering into `lab`.
{ ... }:
{
  flake.nixosModules.lab =
    { lib, ... }:
    {
      # More workers than typical demand, so a task finds an already-warm VM.
      agentFleet.workers = lib.lists.imap1 (index: name: { inherit name index; }) [
        "astrapia"
        "cicinnurus"
        "drepanornis"
        "epimachus"
        "lophorina"
        "manucodia"
        "paradisaea"
        "seleucidis"
      ];

      fleetLogStream.inviteUsers = lib.lists.singleton "@dylan:chat.su.is";

      # Baked in as memo's default so nothing sets MEMORY_DIR at runtime.
      memo.memoryDir = "/home/bridge/cockpit/memory/log";
    };
}
