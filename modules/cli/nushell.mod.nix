# The ship's interactive shell, one config on every host (see
# interactive-shell.mod.nix for how hosts enter it). Cribbed in part
# from rgbcube/ncc.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.nushell;
  flake.homeModules.nushell =
    {
      config,
      osConfig,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.meta) getExe;

      # Build-time LS_COLORS; vivid ships many themes if this one wears.
      lsColors = pkgs.runCommand "ls-colors" { } ''
        ${getExe pkgs.vivid} generate gruvbox-dark-hard > $out
      '';
    in
    {
      # Completer backends for carapace's bridges, not login shells.
      home.packages = [
        pkgs.fish
        pkgs.zsh
      ];

      # External completions for commands nushell doesn't know, bridging
      # into other shells' completion machinery when carapace has no
      # spec of its own (the order CARAPACE_BRIDGES is tried).
      programs.carapace.enable = true;

      # zoxide replaces cd: plain `cd` keeps working, plus frecent
      # jumps like `cd mon` and interactive `cdi`.
      programs.zoxide = {
        enable = true;
        options = [
          "--cmd"
          "cd"
        ];
      };

      programs.nushell = {
        enable = true;
        extraConfig = ''
          $env.config.show_banner = false

          # Mode lives in the cursor: line = insert, block = normal.
          $env.config.edit_mode = "vi"
          $env.config.cursor_shape.emacs = "line"
          $env.config.cursor_shape.vi_insert = "line"
          $env.config.cursor_shape.vi_normal = "block"

          $env.config.history.file_format = "sqlite"
          $env.config.history.max_size = 1_000_000

          # Match anywhere in the word, not just the prefix.
          $env.config.completions.algorithm = "substring"

          $env.CARAPACE_BRIDGES = "zsh,fish,bash"

          $env.LS_COLORS = (open --raw ${lsColors})

          def ship-prompt-path []: nothing -> string {
            let home = ($nu.home-dir | path expand)
            let cwd = ($env.PWD | path expand)
            if $cwd == $home {
              "~"
            } else if ($cwd | str starts-with $"($home)/") {
              $cwd | str replace $home "~"
            } else {
              $cwd
            }
          }

          $env.PROMPT_COMMAND = {||
            $"(ansi green)${config.home.username}@${osConfig.networking.hostName}(ansi reset) (ansi blue)(ship-prompt-path)(ansi reset)"
          }

          # Badges for the command that just ran: nonzero exit code in
          # red, duration once it exceeds 2s.
          $env.PROMPT_COMMAND_RIGHT = {||
            let code = $env.LAST_EXIT_CODE | into int
            let duration = ($env.CMD_DURATION_MS | into int) * 1ms
            [
              (if $code != 0 { $"(ansi red_bold)($code)(ansi reset)" })
              (if $duration > 2sec { $"(ansi magenta)($duration)(ansi reset)" })
            ] | compact | str join " "
          }

          # Past prompts dim once their command has run; badges stay.
          $env.TRANSIENT_PROMPT_COMMAND = {||
            $"(ansi dark_gray)${config.home.username}@${osConfig.networking.hostName} (ship-prompt-path)(ansi reset)"
          }
          $env.TRANSIENT_PROMPT_COMMAND_RIGHT = $env.PROMPT_COMMAND_RIGHT

          alias la = ls --all
          alias ll = ls --long
          alias lla = ls --long --all

          # File operations narrate what they did. rm deliberately does
          # not default --recursive.
          alias cp = cp --recursive --verbose --progress
          alias mv = mv --verbose
          alias rm = rm --verbose

          # Create a directory and cd into it.
          def --env mc [path: path]: nothing -> nothing {
            mkdir $path
            cd $path
          }

          # Ctrl+Alt+C: copy the commandline as a syntax-highlighted
          # ```ansi code block (chat-ready), over OSC 52 so it also
          # works through SSH. Highlighting uses stock colors — custom
          # themes bloat the escape codes past chat size limits.
          use std/clip

          def ship-copy-commandline []: nothing -> nothing {
            let line = commandline
            $env.config.color_config = {}
            [
              "```ansi"
              ($line | nu-highlight)
              "```"
            ]
            | str join (char newline)
            | clip copy52 --ansi
          }

          $env.config.keybindings ++= [
            {
              name: copy_commandline
              modifier: control_alt
              keycode: char_c
              mode: [ emacs vi_insert vi_normal ]
              event: {
                send: executehostcommand
                cmd: "ship-copy-commandline"
              }
            }
          ]
        '';
      };
    };
}
