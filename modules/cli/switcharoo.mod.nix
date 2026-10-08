# switcharoo: pull this machine's flake clone from origin, then switch.
#
# Origin is the repo of record, so the clone is a deploy copy: it always
# lands on origin/main. Local commits are kept on a `switcharoo/saved-*`
# branch and uncommitted edits in a stash before the reset, so nothing is
# lost. If origin can't be reached it stops, unless run with --offline.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.switcharoo;
  flake.homeModules.switcharoo =
    { pkgs, lib, ... }:
    {
      home.packages = lib.lists.singleton (
        pkgs.writers.writeNuBin "switcharoo" # nu
          ''
            def main [--offline] {
              let repo = $env.HOME | path join "ark" "monix"

              if not ($repo | path exists) {
                error make { msg: $"no flake clone at ($repo)" }
              }

              let before = (^git -C $repo rev-parse HEAD | str trim)

              if $offline {
                print $"switcharoo: offline, switching what's on disk \(($before | str substring 0..6)\)"
              } else {
                print "switcharoo: fetching origin"
                let fetch = (do { ^git -C $repo fetch origin main } | complete)
                if $fetch.exit_code != 0 {
                  print --stderr $fetch.stderr
                  error make { msg: "switcharoo: can't reach origin; fix that, or run `switcharoo --offline` to switch what's on disk" }
                }

                let stamp = (date now | format date "%Y%m%d-%H%M%S")
                if (^git -C $repo status --porcelain | str trim | is-not-empty) {
                  ^git -C $repo stash push --include-untracked --message $"switcharoo ($stamp)"
                  print $"switcharoo: uncommitted edits stashed \(git stash list\)"
                }
                let behind = (do { ^git -C $repo merge-base --is-ancestor HEAD origin/main } | complete)
                if $behind.exit_code != 0 {
                  ^git -C $repo branch $"switcharoo/saved-($stamp)" HEAD
                  print $"switcharoo: local commits saved on branch switcharoo/saved-($stamp)"
                }
                ^git -C $repo reset --quiet --hard origin/main
              }

              let after = (^git -C $repo rev-parse HEAD | str trim)
              if $before != $after {
                print $"switcharoo: activating ($before | str substring 0..6)..($after | str substring 0..6)"
                ^git -C $repo log --oneline $"($before)..($after)"
              } else {
                print $"switcharoo: already at ($after | str substring 0..6)"
              }

              let buildDir = $env.HOME | path join ".local" "state" "switcharoo"
              mkdir $buildDir
              let result = $buildDir | path join "result"
              ^nh os build --out-link $result $repo
              if $env.LAST_EXIT_CODE != 0 {
                exit $env.LAST_EXIT_CODE
              }
              let system = (^${lib.meta.getExe' pkgs.coreutils "readlink"} -f $result | str trim)

              # The service and its journal survive restarting the SSH transport.
              print "switcharoo: activating in switcharoo.service; logs: journalctl -fu switcharoo.service"
              ^/run/wrappers/bin/sudo ${lib.meta.getExe' pkgs.systemd "systemd-run"} --unit=switcharoo --collect --service-type=exec --wait --setenv=PATH=/run/wrappers/bin:/run/current-system/sw/bin ${lib.meta.getExe pkgs.nh} os switch --bypass-root-check --no-nom --diff=never $system
            }
          ''
      );
    };
}
