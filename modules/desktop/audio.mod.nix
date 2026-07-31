{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.audio;
  flake.nixosModules.audio = {
    security.rtkit.enable = true;

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
  };
}
