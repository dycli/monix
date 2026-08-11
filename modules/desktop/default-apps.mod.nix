# The desktop's default applications as the desktopApps options. Each app
# carries the package the session launches plus, where it handles files or
# URLs, its .desktop id and the mime types it owns; the xdg mimeApps table
# below is generated from those, so electing an app repoints its keybind,
# its env var, its install and its mime routing from one place. Packages
# install in packages.mod.nix.
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
      inherit (lib.lists) singleton;
      inherit (lib.options) mkOption;
      inherit (lib) types;

      app =
        {
          package,
          desktopId ? null,
          mimeTypes ? [ ],
        }:
        description:
        mkOption {
          inherit description;
          default = { inherit package desktopId mimeTypes; };
          type = types.submodule {
            options = {
              package = mkOption {
                type = types.package;
                description = "the package the session launches for this app";
              };
              desktopId = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "the .desktop id handling this app's mimeTypes, or null if it routes nothing";
              };
              mimeTypes = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "mime types and url schemes this app is the default handler for";
              };
            };
          };
        };
    in
    {
      options.desktopApps = {
        terminal = app { package = pkgs.ghostty; } "terminal emulator the session binds open";

        browser = app {
          package = pkgs.brave;
          desktopId = "brave-browser.desktop";
          mimeTypes = [
            "text/html"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
            "x-scheme-handler/about"
            "x-scheme-handler/unknown"
          ];
        } "web browser; also the URL handler";

        messenger = app { package = pkgs.signal-desktop; } "chat client on the messenger bind";

        passwordManager = app { package = pkgs.keepassxc; } "password manager on its bind";

        email = app {
          package = pkgs.thunderbird;
          desktopId = "thunderbird.desktop";
          mimeTypes = singleton "x-scheme-handler/mailto";
        } "email client; also the mailto handler";

        pdfViewer = app {
          package = pkgs.kdePackages.okular;
          desktopId = "org.kde.okular.desktop";
          mimeTypes = singleton "application/pdf";
        } "PDF viewer behind application/pdf";

        imageViewer = app {
          package = pkgs.kdePackages.gwenview;
          desktopId = "org.kde.gwenview.desktop";
          mimeTypes = [
            "image/avif"
            "image/bmp"
            "image/gif"
            "image/jpeg"
            "image/png"
            "image/svg+xml"
            "image/tiff"
            "image/webp"
          ];
        } "image viewer behind the image/* types";

        videoPlayer = app {
          package = pkgs.haruna;
          desktopId = "org.kde.haruna.desktop";
          mimeTypes = [
            "audio/aac"
            "audio/ac3"
            "audio/flac"
            "audio/mp4"
            "audio/mpeg"
            "audio/ogg"
            "audio/vnd.wave"
            "audio/webm"
            "audio/x-matroska"
            "audio/x-mpegurl"
            "video/mp2t"
            "video/mp4"
            "video/mpeg"
            "video/ogg"
            "video/quicktime"
            "video/vnd.avi"
            "video/webm"
            "video/x-matroska"
            "video/x-ms-wmv"
          ];
        } "video player behind the video/* and audio/* types";

        # A command name, not a package: the editor is the wrapper on the
        # user's PATH from editors.mod.nix, which headless hosts use directly.
        editor = mkOption {
          type = types.str;
          default = "nvim";
          description = "terminal editor command for the session binds and EDITOR";
        };
      };

      config.xdg.mimeApps = {
        enable = true;
        # Each electing app assigns its .desktop id to every mime type it owns.
        defaultApplications = lib.mkMerge (
          lib.attrsets.mapAttrsToList (
            _: elected:
            if lib.isAttrs elected && elected.desktopId != null then
              lib.genAttrs elected.mimeTypes (_: elected.desktopId)
            else
              { }
          ) config.desktopApps
        );
      };
    };
}
