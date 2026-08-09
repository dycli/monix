# The theme option: one ThemeNix palette record every themed surface reads.
{ self, inputs, ... }:
{
  flake.homeModules.desktop = self.homeModules.theme;
  flake.homeModules.theme =
    { lib, ... }:
    {
      options.theme = lib.options.mkOption {
        type = lib.types.attrs;
        description = "base16 palette record (ThemeNix custom shape) owning application theming.";
        default = inputs.themes.custom inputs.themes.raw.grayscale-dark;
      };
    };
}
