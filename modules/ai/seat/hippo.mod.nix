# hippo: the AI seat's episodic memory. One service, running as the seat,
# follows its Claude Code, Codex, Muse Code and OpenCode transcripts live and logs
# every chat word for word; sessions read it through the `hippo` CLI.
# Design: README, "hippo".
{ self, ... }:
let
  # Libri's repository holds hippo; the seat runs the build its link points
  # at, as Libri does (deploy_libri.sh keeps the link).
  package =
    lib: pkgs:
    lib.ship.libriHippo pkgs lib.ship.topology.seat.libriBuild {
      HIPPO_DIR = lib.ship.topology.seat.hippo;
      HIPPO_ARCHIVE = lib.ship.topology.seat.transcripts;
    };
in
{
  # Straight into the seat's bundle: a homeModules.hippo would be mirrored
  # onto the host's primary user (options/flake-outputs.mod.nix).
  flake.homeModules.cockpit =
    { lib, pkgs, ... }:
    {
      home.packages = lib.lists.singleton (package lib pkgs);
    };

  flake.nixosModules.seat = self.nixosModules.hippo;
  flake.nixosModules.hippo =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship) fences topology;
      inherit (topology) seat;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib) types;

      door = config.hippo.door;
      doorPort = 8940;

      # The compactor reaches its model through Libri, on the socket in the
      # store: the person picks it in Libri's Settings, and hippo holds no
      # login and no key.
      compactor.HIPPO_BACKEND = "libri";
    in
    {
      options.hippo.door = {
        passphraseFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Passphrase for the seat's door (hippo.<domain> -> http://127.0.0.1:${toString doorPort}), 12 characters or more; null = no door.";
        };
        tunnelTokenFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Cloudflare Tunnel connector token carrying every hippo door out, the yeomen's too; null = no tunnel.";
        };
      };

      config = {
        # hippo is the only memory: Codex's own stays off.
        seat.codexConfig.features.memories = false;

        systemd.tmpfiles.rules = singleton "d ${seat.hippo} 0750 ${seat.user} ${seat.user} -";

        # A store is bootstrapped by `hippo import` (every past chat) before anything live enters it; the service starts once the
        # import has written its record.
        systemd.paths.hippo = {
          wantedBy = singleton "paths.target";
          pathConfig.PathExists = "${seat.hippo}/import.json";
        };

        systemd.services.hippo = {
          description = "hippo, the AI seat's episodic memory";
          wantedBy = singleton "multi-user.target";
          unitConfig.ConditionPathExists = "${seat.hippo}/import.json";
          # A switch restarts it after the reload: stopped first, hippo.path
          # would start it again on the old unit before the new one loads.
          stopIfChanged = false;
          after = singleton "network-online.target";
          wants = singleton "network-online.target";
          unitConfig.RequiresMountsFor = [
            "/srv/storage"
            seat.home
          ];
          environment = compactor // {
            HOME = seat.home;
            HIPPO_AGENT = "Bridge";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = seat.user;
            Group = seat.user;
            ExecStart = "${lib.meta.getExe (package lib pkgs)} serve code";
            WorkingDirectory = seat.hippo;
            Restart = "always";
            RestartSec = 5;
            # Reads the seat's transcripts; writes its own store.
            ProtectHome = "read-only";
            # SQLite needs OpenCode's WAL index writable even to read.
            ReadWritePaths = [
              seat.hippo
              "-${seat.home}/.local/share/opencode"
            ];
            RestrictAddressFamilies = [ "AF_UNIX" ];
            # The primary user reads the store through the seat's group.
            UMask = "0027";
          };
        };

        # The doors: each memory, read-only, as a remote MCP server for
        # apps outside the ship (Claude, Grok), on its own hostname and
        # passphrase (lib/hippo-door.nix); this one is the seat's. One
        # tunnel carries every door; hostnames map to ports dashboard-side.
        systemd.services.hippo-door = mkIf (door.passphraseFile != null) (
          lib.ship.hippoDoor {
            hippo = package lib pkgs;
            service = "hippo.service";
            dir = seat.hippo;
            inherit (seat) user;
            agent = "Bridge";
            person = "Dylan";
            port = doorPort;
            host = "hippo.${config.shipProxy.domain}";
            inherit (door) passphraseFile;
          }
        );

        systemd.services.hippo-tunnel = mkIf (door.tunnelTokenFile != null) {
          description = "Cloudflare Tunnel for the hippo doors";
          wantedBy = singleton "multi-user.target";
          wants = singleton "network-online.target";
          after = singleton "network-online.target";
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = singleton "token:${door.tunnelTokenFile}";
            ExecStart = "${lib.meta.getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
            # Cloudflare's edge and loopback only; 127.0.0.0/8 is denied
            # because the allow is a /24.
            IPAddressAllow = fences.loopback;
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          };
          environment.TUNNEL_TRANSPORT_PROTOCOL = "http2";
        };
      };
    };
}
