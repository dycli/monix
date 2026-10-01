# The lab role's instance settings: the knobs for the bundle the other
# modules in this directory assemble by registering into `lab`.
{ ... }:
{
  flake.nixosModules.lab =
    { lib, ... }:
    {
      agentFleet.workers =
        lib.lists.imap1
          (index: name: {
            inherit name index;
            mem = 4096;
            vcpu = 4;
          })
          [
            "astrapia"
            "cicinnurus"
          ];

      fleetLogStream.inviteUsers = lib.lists.singleton "@dylan:chat.su.is";

      # Baked in as memo's default so nothing sets MEMORY_DIR at runtime.
      memo.memoryDir = "/home/bridge/.optmem/memory";
    };
}
