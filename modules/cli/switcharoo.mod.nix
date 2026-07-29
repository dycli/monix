# switcharoo — sync this machine's flake clone from wherever its updates
# come from, then switch. One word, any machine.
#
# On fw0 the seat's clone (/home/bridge/ark/monix) is the repo of record:
# the seat commits there and cannot switch (no wheel); the captain
# switches from his own clone. Where the seat clone exists it is pulled
# ff-only first — a failure there is real divergence and stops the switch
# for a human decision. Elsewhere (fw3) the best source is origin, and a
# failed pull only warns: being offline shouldn't block switching to what
# is already on disk.
#
# The commits it pulls are printed before the switch. This is the one
# place where code the AI seat wrote becomes code that runs as root, and
# a one-word command should not make that step invisible — the whole
# containment story assumes the human sees what he is activating.
{
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

              # What this switch is about to activate, in one line each.
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
