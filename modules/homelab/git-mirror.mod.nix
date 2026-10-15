# The git mirror: every repository the GitHub account owns, cloned bare onto
# the NAS and fetched every five minutes, so GitHub is never the only copy.
# The nightly Restic run snapshots /srv/storage, which turns this exact
# mirror into dated history: a force-push or deleted branch upstream reaches
# the mirror, but last night's snapshot still has it. Repositories deleted
# on GitHub stay here. The token is read-only (fine-grained: Contents and
# Metadata), so this copy cannot write back. The seat reads it through the
# group. Water leaves `gitMirror.tokenFile` unset until the token exists.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.git-mirror;
  flake.nixosModules.git-mirror =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) types;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) escapeShellArg;
      inherit (lib.ship) fences hardened;
      inherit (lib.ship.topology) seat;

      cfg = config.gitMirror;
      dir = "/srv/storage/git";

      mirror = pkgs.writeShellApplication {
        name = "git-mirror";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.git
          pkgs.jq
        ];
        text = ''
          root=${escapeShellArg dir}
          GITHUB_TOKEN=$(<"$CREDENTIALS_DIRECTORY/token")
          export GITHUB_TOKEN
          # The helper reads the token from the environment, keeping it out
          # of every command line.
          # shellcheck disable=SC2016
          helper='!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'
          export GIT_TERMINAL_PROMPT=0

          repos=()
          page=1
          while :; do
            batch=$(curl -fsS --max-time 60 \
              -H "Authorization: Bearer $GITHUB_TOKEN" \
              -H "Accept: application/vnd.github+json" \
              "https://api.github.com/user/repos?affiliation=owner&per_page=100&page=$page" |
              jq -r '.[].full_name')
            [[ -z $batch ]] && break
            mapfile -t -O "''${#repos[@]}" repos <<<"$batch"
            page=$((page + 1))
          done
          ((''${#repos[@]})) || { echo "GitHub listed no repositories" >&2; exit 1; }

          failed=0
          for repo in "''${repos[@]}"; do
            target=$root/$repo.git
            if [[ ! -d $target ]]; then
              mkdir -p "$(dirname "$target")"
              if git -c credential.helper="$helper" clone --quiet --mirror \
                "https://github.com/$repo.git" "$target.new"; then
                mv "$target.new" "$target"
              else
                echo "clone failed: $repo" >&2
                rm -rf "$target.new"
                failed=1
              fi
            elif ! git -C "$target" -c credential.helper="$helper" remote update --prune >/dev/null; then
              echo "fetch failed: $repo" >&2
              failed=1
            fi
          done
          ((failed)) && exit 1
          date -Is >"$root/.last-success"
          echo "mirrored ''${#repos[@]} repositories"
        '';
      };
    in
    {
      options.gitMirror.tokenFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Read-only fine-grained GitHub token, raw; null leaves the mirror off.";
      };

      config = mkIf (cfg.tokenFile != null) {
        users.users.git-mirror = {
          isSystemUser = true;
          group = "git-mirror";
        };
        users.groups.git-mirror = { };
        users.users.${seat.user}.extraGroups = singleton "git-mirror";

        systemd.tmpfiles.rules = singleton "d ${dir} 0750 git-mirror git-mirror -";

        systemd.services.git-mirror = {
          description = "Mirror the GitHub account's repositories onto the NAS";
          wants = singleton "network-online.target";
          after = [
            "network-online.target"
            "srv-storage.mount"
          ];
          unitConfig.RequiresMountsFor = dir;
          serviceConfig = hardened.tenant // {
            Type = "oneshot";
            User = "git-mirror";
            Group = "git-mirror";
            ExecStart = getExe mirror;
            LoadCredential = "token:${cfg.tokenFile}";
            ReadWritePaths = singleton dir;
            # The seat reads the mirror through the group.
            UMask = "0027";
            TimeoutStartSec = "30min";
            Nice = 15;
            IOSchedulingClass = "idle";
            # GitHub only; the house stays out of reach.
            IPAddressDeny = fences.internetOnlyDeny;
          };
        };

        systemd.timers.git-mirror = {
          wantedBy = singleton "timers.target";
          timerConfig = {
            OnCalendar = "*:0/5";
            Persistent = true;
          };
        };
      };
    };
}
