{ ... }:
{
  flake.nixosModules.radeon-7900xtx =
    { lib, ... }:
    {
      # Enable OverDrive controls while preserving the current AMDGPU feature mask.
      boot.kernelParams = lib.lists.singleton "amdgpu.ppfeaturemask=0xfff7ffff";

      services.lact = {
        enable = true;
        settings = {
          version = 7;
          daemon = {
            log_level = "info";
            admin_group = "wheel";
          };
          gpus."1002:744C-1EAE:7901-0000:f3:00.0" = {
            power_cap = 294.0;
            performance_level = "manual";
            max_core_clock = 2600;
            voltage_offset = -80;
          };
        };
      };

    };
}
