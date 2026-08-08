# How headless hosts enter nushell; the configuration itself is in
# nushell.mod.nix and desktops launch nu from ghostty. $SHELL stays bash so
# scripts and tools that shell out are unaffected: the re-exec happens in
# bash's interactive init, so `ssh host` lands in nu but `ssh host 'cmd'` does
# not.
{ self, ... }:
{
  flake.homeModules.homelab = self.homeModules.interactive-shell;
  flake.homeModules.ai = self.homeModules.interactive-shell;
  flake.homeModules.interactive-shell =
    { ... }:
    {
      programs.bash = {
        enable = true;
        # nu inherits SHIP_NU, so a bash launched from within nu stays bash.
        initExtra = ''
          if [[ $- == *i* ]] && [[ -z "''${SHIP_NU:-}" ]] && command -v nu >/dev/null 2>&1; then
            export SHIP_NU=1
            exec nu
          fi
        '';
      };
    };
}
