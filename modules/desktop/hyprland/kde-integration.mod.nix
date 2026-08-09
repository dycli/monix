# Qt theming outside Plasma via hyprqt6engine: the platform theme
# (QT_QPA_PLATFORMTHEME in env.mod.nix) hands every Qt6 app the Breeze
# style and the WhiteSur Dark KColorScheme directly from the store. The
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
      # Two fixes over upstream's package: the KF6 libraries are added so
      # CMake's optional detection compiles the KColorScheme loader in
      # (their nix build omits them, silently disabling .colors support),
      # and the plugin dirs are linked into the lib/qt-6/plugins layout
      # QT_PLUGIN_PATH searches.
      engine =
        (inputs.hyprqt6engine.packages.${pkgs.stdenv.hostPlatform.system}.hyprqt6engine).overrideAttrs
          (old: {
            buildInputs = old.buildInputs ++ [
              pkgs.kdePackages.kconfig
              pkgs.kdePackages.kcolorscheme
              pkgs.kdePackages.kiconthemes
            ];
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
            color_scheme = ${inputs.whitesur-kde}/color-schemes/WhiteSurDark.colors
            style = Breeze
            icon_theme = breeze-dark
            font = Noto Sans
            font_size = 10
            font_fixed = ComicCodeLigatures Nerd Font
            font_fixed_size = 10
        }
      '';

      systemd.user.tmpfiles.rules = [
        "f+ %h/.config/kdeglobals 0644 - - - [General]\\nColorScheme=WhiteSurDark\\n[KDE]\\nwidgetStyle=Breeze\\n[Icons]\\nTheme=breeze-dark\\n"
      ];

      # Named lookups (kdeglobals) resolve through the data dirs.
      xdg.dataFile."color-schemes/WhiteSurDark.colors".source =
        "${inputs.whitesur-kde}/color-schemes/WhiteSurDark.colors";
    };
}
