# `open` picks by mime type: text-like files go to $EDITOR in the same
# terminal, everything else is dispatched async to xdg-open. A headless
# host has no xdg-open, so non-text files do not open there.
{
  flake.homeModules.lf =
    { pkgs, ... }:
    {
      programs.lf = {
        enable = true;

        # `w` spawns $SHELL, which is bash; the interactive shell is nu.
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
