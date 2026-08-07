# How hosts enter nushell (the config itself is nushell.mod.nix, on
# every host via the default bundle). $SHELL stays bash so scripts and
# tools that shell out are unaffected. Desktops launch nu from ghostty
# (see ghostty.mod.nix); headless hosts re-exec into it from bash's
# interactive init, so plain `ssh host` lands in nu but `ssh host 'cmd'`
# does not.
{ self, ... }:
{
  flake.homeModules.homelab = self.homeModules.interactive-shell;
  flake.homeModules.ai = self.homeModules.interactive-shell;
  flake.homeModules.interactive-shell =
    { ... }:
    {
      programs.bash = {
        enable = true;
        # Interactive shells only, once only — SHIP_NU is inherited by
        # nu, so a bash launched from within nu stays bash — and only
        # when nu exists.
        initExtra = ''
          if [[ $- == *i* ]] && [[ -z "''${SHIP_NU:-}" ]] && command -v nu >/dev/null 2>&1; then
            export SHIP_NU=1
            exec nu
          fi
        '';
      };
    };
}
