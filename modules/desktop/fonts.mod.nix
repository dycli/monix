# Fonts: CaskaydiaMono Nerd Font is what the ghostty/DMS configs reference.
# `noto-fonts-color-emoji` is the current attribute name (noto-fonts-emoji is
# a deprecated alias).
{
  flake.nixosModules.fonts =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf config.isDesktop {
        fonts.enableDefaultPackages = true;

        fonts.packages = [
          pkgs.noto-fonts
          pkgs.noto-fonts-color-emoji
          pkgs.nerd-fonts.caskaydia-mono
        ];

        fonts.fontconfig.defaultFonts = {
          monospace = [ "CaskaydiaMono Nerd Font" ];
          sansSerif = [ "Noto Sans" ];
          serif = [ "Noto Serif" ];
          emoji = [ "Noto Color Emoji" ];
        };
      };
    };
}
