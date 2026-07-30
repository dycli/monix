# On headless hosts, interactive shells are nushell while $SHELL stays
# bash. bash's interactive init re-execs into nu, so scripts, `ssh host
# 'cmd'` and tools that shell out via $SHELL are unaffected.
#
# Desktops get the same split from ghostty instead, so this is gated to
# non-desktops.
{
  flake.homeModules.interactive-shell =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    {
      config = lib.mkIf (!osConfig.isDesktop) {
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
    };
}
