# File manager. `open` picks by mime type: text-like files go to $EDITOR in the
# same terminal, everything else is dispatched async to xdg-open, which a
# headless host does not have. Desktops add photo rendering in the preview
# pane; headless hosts keep lf's built-in text preview.
{ self, ... }:
let
  # Types that read as text in a terminal, shared by `open` and the previewer.
  textLike = "text/* | application/json | application/javascript | application/x-shellscript | application/toml | application/yaml | application/xml | inode/x-empty";
in
{
  flake.homeModules.default = self.homeModules.lf;
  flake.homeModules.lf =
    { lib, pkgs, ... }:
    let
      inherit (lib.meta) getExe';
    in
    {
      # Filetype icon map from voidrice; lf reads the file natively.
      xdg.configFile."lf/icons".source = ./lf-icons.tsv;

      programs.lf = {
        enable = true;

        settings.icons = true;

        # `w` would otherwise spawn $SHELL, which is bash.
        keybindings.w = "$" + getExe' pkgs.nushell "nu";

        commands.open = ''
          ''${{
            # $fx is newline-separated; under the default IFS, names with
            # spaces would split into nonexistent paths.
            IFS="$(printf '\n\t')"
            set -f
            case $(${getExe' pkgs.file "file"} --mime-type -Lb "$f") in
              ${textLike})
                $EDITOR $fx
                ;;
              *)
                for f in $fx; do
                  ${getExe' pkgs.util-linux "setsid"} -f ${getExe' pkgs.xdg-utils "xdg-open"} "$f" \
                    >/dev/null 2>&1
                done
                ;;
            esac
          }}
        '';
      };
    };

  # ghostty speaks the kitty graphics protocol, so kitten icat can draw
  # images into the preview rectangle lf hands the previewer. The drawing
  # happens out of band, so the image case exits non-zero to keep lf from
  # caching an empty pane, and the cleaner erases it on the way out.
  flake.homeModules.desktop = self.homeModules.lf-previews;
  flake.homeModules.lf-previews =
    { lib, pkgs, ... }:
    let
      inherit (lib.meta) getExe';
      # The pinned transfer mode matters: without it icat probes the terminal
      # for protocol support and reads the reply from the tty, racing lf for
      # input — keystrokes leak into lf's prompt and icat hangs. stream is
      # the base protocol every kitty-graphics terminal supports.
      icat = "${getExe' pkgs.kitty.kitten "kitten"} icat --silent --stdin=no --transfer-mode=stream";
    in
    {
      programs.lf = {
        previewer.source = pkgs.writeShellScript "lf-preview" ''
          case "$(${getExe' pkgs.file "file"} --mime-type -Lb "$1")" in
            image/*)
              ${icat} --place "''${2}x''${3}@''${4}x''${5}" "$1" </dev/null >/dev/tty
              exit 1
              ;;
            ${textLike})
              ${getExe' pkgs.coreutils "cat"} "$1"
              ;;
            *)
              ${getExe' pkgs.file "file"} -Lb "$1"
              ;;
          esac
        '';
        settings.cleaner = "${pkgs.writeShellScript "lf-clean" ''
          ${icat} --clear </dev/null >/dev/tty
        ''}";
      };
    };
}
