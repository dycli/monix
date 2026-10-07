# hippo: the AI seat's episodic memory. One service, running as the seat,
# follows its Claude Code, Codex and OpenCode transcripts live and logs
# every chat word for word; sessions read it through the `hippo` CLI.
# Design: ~/cockpit/hippo/SPEC.md.
{ self, ... }:
let
  package =
    lib: pkgs:
    lib.ship.rustTool pkgs {
      src = ./hippo;
      env = {
        HIPPO_DIR = lib.ship.topology.seat.hippo;
        HIPPO_ARCHIVE = lib.ship.topology.seat.transcripts;
      };
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

      # The compactor's model: Sonnet at medium effort through the seat's own
      # claude CLI and subscription. HIPPO_BACKEND = "http" with HIPPO_URL
      # (and HIPPO_KEY_FILE) points it at any OpenAI-compatible endpoint.
      compactor = {
        HIPPO_BACKEND = "claude";
        HIPPO_CLAUDE = "/etc/profiles/per-user/${seat.user}/bin/claude";
        HIPPO_MODEL = "sonnet";
        HIPPO_EFFORT = "medium";
      };

      # The seat's managed settings without its managed MCP servers: those
      # would start a browser and Tailscale SSH sessions on every compactor
      # call, and their presence forbids --strict-mcp-config.
      claudeEtc =
        pkgs.writeTextDir "managed-settings.json"
          config.environment.etc."claude-code/managed-settings.json".text;
    in
    {
      systemd.tmpfiles.rules = singleton "d ${seat.hippo} 0750 ${seat.user} ${seat.user} -";

      # A store is bootstrapped by `hippo import` (OptMem's notes and every
      # past chat) before anything live enters it; the service starts once the
      # import has written its record.
      systemd.paths.hippo = {
        wantedBy = singleton "paths.target";
        pathConfig.PathExists = "${seat.hippo}/import.json";
      };

      systemd.services.hippo = {
        description = "hippo, the AI seat's episodic memory";
        wantedBy = singleton "multi-user.target";
        unitConfig.ConditionPathExists = "${seat.hippo}/import.json";
        after = singleton "network-online.target";
        wants = singleton "network-online.target";
        unitConfig.RequiresMountsFor = [
          "/srv/storage"
          seat.home
        ];
        environment = compactor // {
          HOME = seat.home;
        };
        serviceConfig = lib.ship.hardened.tenant // {
          User = seat.user;
          Group = seat.user;
          ExecStart = "${lib.meta.getExe (package lib pkgs)} serve";
          WorkingDirectory = seat.hippo;
          Restart = "always";
          RestartSec = 5;
          # Reads the seat's transcripts; writes its own store, and the claude
          # CLI's state and refreshed credentials.
          ProtectHome = "read-only";
          # SQLite needs OpenCode's WAL index writable even to read.
          ReadWritePaths = [
            seat.hippo
            "-${seat.home}/.local/share/opencode"
            "${seat.home}/.claude"
            "${seat.home}/.claude.json"
          ];
          BindReadOnlyPaths = singleton "${claudeEtc}:/etc/claude-code";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          # The seat's own fence: the internet and the resolver only.
          IPAddressAllow = singleton "127.0.0.53/32";
          IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          # The primary user reads the store through the seat's group.
          UMask = "0027";
        };
      };
    };
}
