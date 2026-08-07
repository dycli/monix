# Nushell is the ship's interactive shell; $SHELL stays bash so scripts
# and tools that shell out are unaffected. The config rides the default
# bundle — every host gets the same shell — while how nu is entered
# differs by role: desktops launch it from ghostty (see ghostty.mod.nix),
# headless hosts re-exec into it from bash's interactive init, so plain
# `ssh host` lands in nu but `ssh host 'cmd'` does not.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.nushell;
  flake.homeModules.nushell =
    {
      config,
      osConfig,
      ...
    }:
    {
      programs.nushell = {
        enable = true;
        extraConfig = ''
          $env.config.show_banner = false
          $env.PROMPT_COMMAND = {||
            let home = ($nu.home-dir | path expand)
            let cwd = ($env.PWD | path expand)
            let display_path = if $cwd == $home {
              "~"
            } else if ($cwd | str starts-with $"($home)/") {
              $cwd | str replace $home "~"
            } else {
              $cwd
            }

            $"(ansi green)${config.home.username}@${osConfig.networking.hostName}(ansi reset) (ansi blue)($display_path)(ansi reset)"
          }
          $env.PROMPT_COMMAND_RIGHT = {|| "" }
        '';
      };
    };

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
