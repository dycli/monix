# switcharoo: pull this machine's flake clone from origin, then switch.
#
# Origin is the repo of record, so hosts converge only on published history;
# unpushed commits in another clone are invisible here. A failed pull only
# warns, leaving an offline host able to switch what is on disk.
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

              ^nh os switch $repo
            }
          ''
        )
      ];
    };
}
