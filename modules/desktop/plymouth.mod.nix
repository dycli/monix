# Graphical boot splash and LUKS prompt. amdgpu's modeset completes a
# second or two into boot, asynchronously, and a plain console prompt can
# land before it and be left on a stale pre-modeset frame. Plymouth
# watches DRM devices and repaints when the driver takes over.
#
# Early KMS is a prerequisite, already provided by nixos-hardware.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.plymouth;
  flake.nixosModules.plymouth =
    { lib, ... }:
    {
      boot.plymouth.enable = true;

      # The console must stop writing over the splash.
      boot.initrd.verbose = lib.modules.mkDefault false;
      boot.kernelParams = [
        "quiet"
        "udev.log_level=3"
      ];
    };
}
