# usage: the seat's Claude subscription limits, read from the endpoint behind
# Claude Code's /usage with the seat's own login, so a session can plan
# model-heavy runs. Undocumented; expect it to change.
{
  flake.homeModules.cockpit =
    { lib, pkgs, ... }:
    {
      home.packages = lib.lists.singleton (
        pkgs.writeShellApplication {
          name = "usage";
          runtimeInputs = [
            pkgs.curl
            pkgs.jq
            pkgs.coreutils
          ];
          text = ''
            token=$(jq -er .claudeAiOauth.accessToken ~/.claude/.credentials.json)
            out=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
              | curl -sf -m 15 -K - -H "anthropic-beta: oauth-2025-04-20" \
                  https://api.anthropic.com/api/oauth/usage) \
              || { echo "usage: request failed (login expired? run claude once)" >&2; exit 1; }
            for window in five_hour seven_day; do
              pct=$(jq -r ".$window.utilization // empty" <<< "$out")
              at=$(jq -r ".$window.resets_at // empty" <<< "$out")
              [ -n "$pct" ] || continue
              printf '%-9s %3.0f%%  resets %s\n' "$window" "$pct" "$(date -d "$at" '+%a %H:%M')"
            done
          '';
        }
      );
    };
}
