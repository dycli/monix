# switcharoo — pull this machine's flake clone, then switch.
#
# Where the seat's clone (/home/bridge/ark/monix) exists it is the source
# and a failed ff-only pull aborts, since that means divergence. Elsewhere
# the source is origin and a failed pull only warns, so being offline
# still switches what is on disk.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.switcharoo;
  flake.homeModules.switcharoo =
    { pkgs, ... }:
    {
      home.packages = [
        (pkgs.writers.writeNuBin "switcharoo" # nu
          ''
            def main [] {
              let repo = $env.HOME | path join "ark" "monix"
              let record = "/home/bridge/ark/monix"

              if not ($repo | path exists) {
                error make { msg: $"no flake clone at ($repo)" }
              }

              let before = (^git -C $repo rev-parse HEAD | str trim)

              if ($record | path exists) and $repo != $record {
                print $"switcharoo: pulling the repo of record ($record)"
                ^git -C $repo pull --ff-only $record main
              } else if (^git -C $repo remote | lines | any {|r| $r == "origin" }) {
                print "switcharoo: pulling origin"
                try {
                  ^git -C $repo pull --ff-only origin main
                } catch {
                  print --stderr "switcharoo: pull failed; switching to what's on disk"
                }
              }

              let after = (^git -C $repo rev-parse HEAD | str trim)
              if $before != $after {
                print $"switcharoo: activating ($before | str substring 0..6)..($after | str substring 0..6)"
                ^git -C $repo log --oneline $"($before)..($after)"
              }

              ^nh os switch $repo
            }
          ''
        )
      ];
    };
}
