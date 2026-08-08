# GTK theming from the theme palette. adwaitaGtkCss defines the libadwaita
# named colors; adw-gtk3 (GTK_THEME, env.mod.nix) consumes them in GTK3 and
# libadwaita apps read them natively in GTK4.
{ self, ... }:
{
  flake.homeModules.desktop = self.homeModules.gtk;
  flake.homeModules.gtk =
    { config, pkgs, ... }:
    {
      home.packages = [ pkgs.adw-gtk3 ];

      # force: DMS wrote these at runtime before the theme owned them, and
      # stale copies plus their backups otherwise fail activation.
      xdg.configFile."gtk-3.0/gtk.css" = {
        text = config.theme.adwaitaGtkCss;
        force = true;
      };
      xdg.configFile."gtk-4.0/gtk.css" = {
        text = config.theme.adwaitaGtkCss;
        force = true;
      };
    };
}
