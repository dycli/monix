# The desktop's default applications, declared once as the desktopApps
# options; everything else references them. The session binds
# (hyprland.mod.nix) launch them, and the xdg mime pins route file and
# URL opens to them by declaration, not by whichever app registered
# itself first at runtime. Hosts override per-app.
#
# This module only elects defaults — every desktop application installs
# in packages.mod.nix (the session-bound ones there reference these
# options, so a host override changes both the binds and the install).
# The mime desktop ids below must follow the chosen packages.
{ self, ... }:
{
  flake.homeModules.desktop = self.homeModules.default-apps;
  flake.homeModules.default-apps =
    { lib, pkgs, ... }:
    let
      inherit (lib.options) mkOption;
      inherit (lib) types;

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
        pdfViewer = app pkgs.kdePackages.okular "PDF viewer behind application/pdf";
        imageViewer = app pkgs.kdePackages.gwenview "image viewer behind the image/* types";
        videoPlayer = app pkgs.haruna "video player behind the video/* and audio/* types";

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
        xdg.mimeApps = {
          enable = true;
          defaultApplications = {
            "text/html" = "brave-browser.desktop";
            "x-scheme-handler/http" = "brave-browser.desktop";
            "x-scheme-handler/https" = "brave-browser.desktop";
            "x-scheme-handler/about" = "brave-browser.desktop";
            "x-scheme-handler/unknown" = "brave-browser.desktop";

            "x-scheme-handler/mailto" = "thunderbird.desktop";

            "application/pdf" = "org.kde.okular.desktop";

            "image/avif" = "org.kde.gwenview.desktop";
            "image/bmp" = "org.kde.gwenview.desktop";
            "image/gif" = "org.kde.gwenview.desktop";
            "image/jpeg" = "org.kde.gwenview.desktop";
            "image/png" = "org.kde.gwenview.desktop";
            "image/svg+xml" = "org.kde.gwenview.desktop";
            "image/tiff" = "org.kde.gwenview.desktop";
            "image/webp" = "org.kde.gwenview.desktop";

            "audio/aac" = "org.kde.haruna.desktop";
            "audio/ac3" = "org.kde.haruna.desktop";
            "audio/flac" = "org.kde.haruna.desktop";
            "audio/mp4" = "org.kde.haruna.desktop";
            "audio/mpeg" = "org.kde.haruna.desktop";
            "audio/ogg" = "org.kde.haruna.desktop";
            "audio/vnd.wave" = "org.kde.haruna.desktop";
            "audio/webm" = "org.kde.haruna.desktop";
            "audio/x-matroska" = "org.kde.haruna.desktop";
            "audio/x-mpegurl" = "org.kde.haruna.desktop";
            "video/mp2t" = "org.kde.haruna.desktop";
            "video/mp4" = "org.kde.haruna.desktop";
            "video/mpeg" = "org.kde.haruna.desktop";
            "video/ogg" = "org.kde.haruna.desktop";
            "video/quicktime" = "org.kde.haruna.desktop";
            "video/vnd.avi" = "org.kde.haruna.desktop";
            "video/webm" = "org.kde.haruna.desktop";
            "video/x-matroska" = "org.kde.haruna.desktop";
            "video/x-ms-wmv" = "org.kde.haruna.desktop";
          };
        };
      };
    };
}
