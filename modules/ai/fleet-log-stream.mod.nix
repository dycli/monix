# Tails the agent-fleet audit log into a Matrix room. The room is created on
# first start and remembered in the state directory, never in the repo.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.fleet-log-stream;
  flake.nixosModules.fleet-log-stream =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.strings) toJSON;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.fleetLogStream;
      inherit (lib.ship) topology;
      fleetLog = "${topology.tasksDir}/log";
    in
    {
      options.fleetLogStream = {
        credentialsEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix env file with MATRIX_USER=@bot:server and
            MATRIX_PASSWORD=... — normally the same file the alerts
            aspect uses (any ALERT_ROOM_ID in it is ignored here).
          '';
        };

        homeserverUrl = mkOption {
          type = types.str;
          default = "http://127.0.0.1:${toString config.matrix.port}";
          description = "Homeserver base URL (default: the loopback tuwunel).";
        };

        roomName = mkOption {
          type = types.str;
          default = "Fleet Ops";
          description = "Display name for the room the bot creates on first start.";
        };

        inviteUsers = mkOption {
          type = types.listOf types.str;
          description = "Matrix ids invited to the feed room when it is first created.";
        };
      };

      config = {
        systemd.services.fleet-log-stream = {
          description = "Stream the fleet audit log to Matrix";
          wantedBy = singleton "multi-user.target";
          startLimitIntervalSec = 0;
          # The readers group grants the dynamic user the audit log, which is
          # not world-readable. Egress is loopback-only for the local
          # homeserver.
          serviceConfig = lib.ship.hardened.tenant // {
            DynamicUser = true;
            SupplementaryGroups = singleton topology.readersGroup;
            StateDirectory = "fleet-log-stream";
            RuntimeDirectory = "fleet-log-stream";
            RuntimeDirectoryMode = "0700";
            EnvironmentFile = cfg.credentialsEnvFile;
            Restart = "always";
            RestartSec = 10;

            IPAddressAllow = fences.loopback;
            IPAddressDeny = "any";
          };
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.jq
          ];
          script = ''
            hs=${lib.escapeShellArg cfg.homeserverUrl}
            state=/var/lib/fleet-log-stream
            hdr=/run/fleet-log-stream/auth-header

            mcurl() {
              curl -sf --connect-timeout 5 --max-time 30 \
                -H "Content-Type: application/json" "$@"
            }

            # /proc/<pid>/cmdline is world-readable, so credentials and log
            # content never ride argv: jq reads them from the environment,
            # request bodies arrive on stdin, and the bearer header lives in
            # the private runtime dir.
            acurl() {
              mcurl -H @"$hdr" "$@"
            }

            tok=$(jq -n '{type:"m.login.password",
                identifier:{type:"m.id.user",user:env.MATRIX_USER},
                password:env.MATRIX_PASSWORD}' \
              | mcurl -X POST "$hs/_matrix/client/v3/login" -d @- \
              | jq -er .access_token)
            printf 'Authorization: Bearer %s\n' "$tok" > "$hdr"
            unset tok
            trap 'acurl -X POST "$hs/_matrix/client/v3/logout" -d "{}" > /dev/null || true' EXIT

            # First start: create the private feed room, invite the crew,
            # remember the id. The room is the bot's own — no secret, no
            # repo state. If creation fails, exit and let Restart retry.
            if [ ! -s "$state/room-id" ]; then
              room_id=$(jq -n --arg n ${lib.escapeShellArg cfg.roomName} \
                  --argjson inv ${lib.escapeShellArg (toJSON cfg.inviteUsers)} \
                  '{name:$n, preset:"private_chat", invite:$inv,
                    topic:"Live fleet audit log — every SUBMIT/DISPATCH/ESCALATE/STEER/ANSWER/DONE as it happens"}' \
                | acurl -X POST "$hs/_matrix/client/v3/createRoom" -d @- \
                | jq -er .room_id)
              printf '%s\n' "$room_id" > "$state/room-id"
            fi
            room=$(jq -rn --arg r "$(cat "$state/room-id")" '$r|@uri')

            send() {
              b="$1" jq -n '{msgtype:"m.text",body:env.b}' \
                | acurl -X PUT \
                  "$hs/_matrix/client/v3/rooms/$room/send/m.room.message/$(date +%s%N)-$$" \
                  -d @- > /dev/null \
                || {
                  echo "send failed, batch dropped; restarting to refresh login" >&2
                  return 1
                }
            }

            # Stream: first line of a batch blocks indefinitely; once one
            # arrives, keep absorbing lines until 2s of quiet, then post
            # the batch as a single message. Lossy by design: -n 0 keeps no
            # cursor, so lines logged while this unit is down never reach
            # the room — the on-disk log is the durable record.
            batch=""
            while IFS= read -r line; do
              batch="$line"
              while IFS= read -r -t 2 more; do
                batch="$batch
            $more"
              done
              send "$batch" || exit 1
              batch=""
            done < <(tail -F -n 0 ${fleetLog})
          '';
        };
      };
    };
}
