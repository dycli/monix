# File manager. `open` picks by mime type: text-like files go to $EDITOR in the
# same terminal, everything else is dispatched async to xdg-open, which a
# headless host does not have.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.lf;
  flake.homeModules.lf =
    { pkgs, ... }:
    {
      programs.lf = {
        enable = true;

        # `w` would otherwise spawn $SHELL, which is bash.
        keybindings.w = "$" + "${pkgs.nushell}/bin/nu";

        commands.open = ''
          ''${{
            case $(${pkgs.file}/bin/file --mime-type -Lb "$f") in
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
