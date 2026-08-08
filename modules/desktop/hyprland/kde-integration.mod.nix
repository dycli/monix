# KDE apps outside Plasma: plugin discovery and theming.
#
# qt.enable adds every profile's Qt plugin dirs to the session env;
# QT_QPA_PLATFORMTHEME=kde (env.mod.nix) then loads plasma-integration, which
# makes every Qt app — KDE or not — read kdeglobals for colors, widget style,
# fonts and icons. kdeglobals is the single Qt theming source, rendered from
# the theme palette.
{ self, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.kde-integration;
  flake.nixosModules.kde-integration = {
    qt.enable = true;
  };

  flake.homeModules.hyprland = self.homeModules.kde-integration;

  flake.homeModules.kde-integration =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      t = config.theme;

      # KColorScheme color values are decimal "r,g,b".
      rgb =
        hex:
        [ 0 2 4 ]
        |> map (i: builtins.substring i 2 hex |> lib.fromHexString |> toString)
        |> lib.concatStringsSep ",";

      mkSection = name: bg: alt: fg: ''
        [Colors:${name}]
        BackgroundNormal=${rgb bg}
        BackgroundAlternate=${rgb alt}
        ForegroundNormal=${rgb fg}
        ForegroundInactive=${rgb t.base03}
        ForegroundActive=${rgb t.base0C}
        ForegroundLink=${rgb t.base0D}
        ForegroundVisited=${rgb t.base0E}
        ForegroundNegative=${rgb t.base08}
        ForegroundNeutral=${rgb t.base0A}
        ForegroundPositive=${rgb t.base0B}
        DecorationFocus=${rgb t.base0D}
        DecorationHover=${rgb t.base0D}
      '';
    in
    {
      home.packages = [
        pkgs.kdePackages.plasma-integration
        pkgs.kdePackages.breeze
      ];

      xdg.dataFile."color-schemes/Monix.colors".text = ''
        [General]
        ColorScheme=Monix
        Name=Monix
      ''
      + mkSection "View" t.base00 t.base01 t.base05
      + mkSection "Window" t.base01 t.base02 t.base05
      + mkSection "Button" t.base01 t.base02 t.base05
      + mkSection "Selection" t.base0D t.base0D t.base00
      + mkSection "Tooltip" t.base01 t.base02 t.base05
      + mkSection "Complementary" t.base00 t.base01 t.base05;

      # KDE apps write back to kdeglobals at runtime, so it cannot be a store
      # symlink; f+ reasserts the declared content at each boot.
      systemd.user.tmpfiles.rules = [
        "f+ %h/.config/kdeglobals 0644 - - - [General]\\nColorScheme=Monix\\n[KDE]\\nwidgetStyle=Breeze\\n[Icons]\\nTheme=${
          if t.isDark then "breeze-dark" else "breeze"
        }\\n"
      ];
    };
}
