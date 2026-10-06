# ZSA keyboard access (Oryx, Keymapp, Wally) for the seat user on every desktop.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.zsa;
  flake.nixosModules.zsa = {
    hardware.keyboard.zsa.enable = true;
  };
}
