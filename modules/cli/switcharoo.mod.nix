# switcharoo — pull this machine's flake clone from origin, then switch.
#
# Origin is the repo of record: the seat pushes reviewed commits there,
# and hosts converge only on published history — commits sitting in the
# seat's working clone are invisible until pushed. A failed pull only
# warns, so being offline still switches what is on disk.
#
# `switcharoo <host>` names the flake attribute explicitly, for when it
# differs from the running hostname — a host's first switch across a
# rename (fw0 running, attribute now `water`) or a fresh bootstrap.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.switcharoo;
  flake.homeModules.switcharoo =
    { pkgs, ... }:
    {
      home.packages = [
        (pkgs.writers.writeNuBin "switcharoo" # nu
          ''
            def main [host?: string] {
              let repo = $env.HOME | path join "ark" "monix"

              if not ($repo | path exists) {
                error make { msg: $"no flake clone at ($repo)" }
              }

              let before = (^git -C $repo rev-parse HEAD | str trim)

              if (^git -C $repo remote | lines | any {|r| $r == "origin" }) {
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

              if $host == null {
                ^nh os switch $repo
              } else {
                ^nh os switch $"($repo)#($host)"
              }
            }
          ''
        )
      ];
    };
}
