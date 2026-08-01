# The desktop's default applications, declared once as the desktopApps
# options; everything else references them. The session binds
# (hyprland.mod.nix) launch them, and the xdg mime pins route file and
# URL opens to them by declaration, not by whichever app registered
# itself first at runtime. Hosts override per-app.
#
# The desktop ids must follow the chosen packages. Installation of the
# big GUI apps stays in packages.mod.nix — this module elects defaults
# (and installs the two viewers nothing else carries).
{ self, ... }:
{
  flake.homeModules.desktop = self.homeModules.default-apps;
  flake.homeModules.default-apps =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.options) mkOption;
      inherit (lib) types;

      cfg = config.desktopApps;

      app =
        default: description:
        mkOption {
          type = types.package;
          inherit default description;
        };
    in
    {
      options.desktopApps = {
        terminal = app pkgs.ghostty "terminal emulator the session binds open";
        browser = app pkgs.brave "web browser; also the URL handler below";
        messenger = app pkgs.signal-desktop "chat client on the messenger bind";
        passwordManager = app pkgs.keepassxc "password manager on its bind";
        email = app pkgs.thunderbird "email client; also the mailto handler";
        pdfViewer = app pkgs.zathura "PDF viewer behind application/pdf";
        imageViewer = app pkgs.imv "image viewer behind the image/* types";

        # A command name, not a package: the editor is the NvChad wrapper
        # on the user's PATH (editors.mod.nix). Session-scoped — headless
        # hosts get their EDITOR from that module directly.
        editor = mkOption {
          type = types.str;
          default = "nvim";
          description = "terminal editor command for the session binds and EDITOR";
        };
      };

      config = {
        home.packages = [
          cfg.email
          cfg.pdfViewer
          cfg.imageViewer
        ];

        xdg.mimeApps = {
          enable = true;
          defaultApplications = {
            "text/html" = "brave-browser.desktop";
            "x-scheme-handler/http" = "brave-browser.desktop";
            "x-scheme-handler/https" = "brave-browser.desktop";
            "x-scheme-handler/about" = "brave-browser.desktop";
            "x-scheme-handler/unknown" = "brave-browser.desktop";

            "x-scheme-handler/mailto" = "thunderbird.desktop";

            "application/pdf" = "org.pwmt.zathura.desktop";

            "image/avif" = "imv.desktop";
            "image/bmp" = "imv.desktop";
            "image/gif" = "imv.desktop";
            "image/jpeg" = "imv.desktop";
            "image/png" = "imv.desktop";
            "image/svg+xml" = "imv.desktop";
            "image/tiff" = "imv.desktop";
            "image/webp" = "imv.desktop";
          };
        };
      };
    };
}
