# Qt theming outside Plasma via hyprqt6engine: the platform theme
# (QT_QPA_PLATFORMTHEME in env.mod.nix) hands every Qt6 app the Breeze
# style and the BreezeDark KColorScheme directly from the store. The
# plugin follows this flake's nixpkgs so it links the same Qt as the
# applications. qt.enable provides QT_PLUGIN_PATH.
#
# kdeglobals stays for KDE apps that consult it beyond the palette; KDE
# apps write back to it at runtime, so it cannot be a store symlink and
# f+ reasserts the declared content at each boot.
{ self, inputs, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.kde-integration;
  flake.nixosModules.kde-integration = {
    qt.enable = true;
  };

  flake.homeModules.hyprland = self.homeModules.kde-integration;

  flake.homeModules.kde-integration =
    { pkgs, ... }:
    let
      # Upstream installs to lib/qt-6/{platformthemes,styles}; Qt searches
      # QT_PLUGIN_PATH entries ending in lib/qt-6/plugins, so the plugin
      # dirs are linked into that layout.
      engine =
        (inputs.hyprqt6engine.packages.${pkgs.stdenv.hostPlatform.system}.hyprqt6engine).overrideAttrs
          (old: {
            postInstall = (old.postInstall or "") + ''
              mkdir -p $out/lib/qt-6/plugins
              ln -s $out/lib/qt-6/platformthemes $out/lib/qt-6/plugins/platformthemes
              ln -s $out/lib/qt-6/styles $out/lib/qt-6/plugins/styles
            '';
          });
    in
    {
      home.packages = [
        engine
        pkgs.kdePackages.breeze
      ];

      xdg.configFile."hypr/hyprqt6engine.conf".text = ''
        theme {
            color_scheme = ${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors
            style = Breeze
            icon_theme = breeze-dark
            font = Noto Sans
            font_size = 10
            font_fixed = ComicCodeLigatures Nerd Font
            font_fixed_size = 10
        }
      '';

      systemd.user.tmpfiles.rules = [
        "f+ %h/.config/kdeglobals 0644 - - - [General]\\nColorScheme=BreezeDark\\n[KDE]\\nwidgetStyle=Breeze\\n[Icons]\\nTheme=breeze-dark\\n"
      ];
    };
}
