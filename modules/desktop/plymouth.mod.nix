# Graphical boot splash and LUKS prompt. amdgpu's modeset completes a
# second or two into boot, asynchronously, and a plain console prompt can
# land before it and be left on a stale pre-modeset frame. Plymouth
# watches DRM devices and repaints when the driver takes over.
#
# Early KMS is a prerequisite, already provided by nixos-hardware.
{
  flake.nixosModules.plymouth =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
    in
    {
      config = mkIf config.isDesktop {
        boot.plymouth.enable = true;

        # The console must stop writing over the splash.
        boot.initrd.verbose = mkDefault false;
        boot.kernelParams = [
          "quiet"
          "udev.log_level=3"
        ];
      };
    };
}
