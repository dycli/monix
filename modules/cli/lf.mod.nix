# File manager. `open` picks by mime type: text-like files go to $EDITOR in the
# same terminal, everything else is dispatched async to xdg-open, which a
# headless host does not have.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.lf;
  flake.homeModules.lf =
    { lib, pkgs, ... }:
    let
      inherit (lib.meta) getExe';
    in
    {
      programs.lf = {
        enable = true;

        # `w` would otherwise spawn $SHELL, which is bash.
        keybindings.w = "$" + getExe' pkgs.nushell "nu";

        commands.open = ''
          ''${{
            # $fx is newline-separated; under the default IFS, names with
            # spaces would split into nonexistent paths.
            IFS="$(printf '\n\t')"
            set -f
            case $(${getExe' pkgs.file "file"} --mime-type -Lb "$f") in
              text/* | application/json | application/javascript | application/x-shellscript | application/toml | application/yaml | application/xml | inode/x-empty)
                $EDITOR $fx
                ;;
              *)
                for f in $fx; do
                  setsid -f xdg-open "$f" >/dev/null 2>&1
                done
                ;;
            esac
          }}
        '';
      };
    };
}
