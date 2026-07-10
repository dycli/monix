# Cockpit: the user's primary interactive Claude Code session lives on the
# host that enables this, inside tmux, attached over tailnet SSH from any
# machine. The session runs as the primary user with normal interactive
# permission prompts — it is the human's seat, not an autonomous agent, so it
# carries full user privileges (contrast with the locked-down fleet workers
# of agent-vm.mod.nix). Usage: `ssh fw0` then `tmux new -As main`.
#
# The agent tooling itself (claude-code, codex, CLAUDE.md) comes from the
# existing home aspects in packages.mod.nix / claude.mod.nix, which gate on
# `isDesktop || cockpit.enable`.
{ inputs, ... }:
{
  flake.homeModules.cockpit =
    { lib, osConfig, ... }:
    let
      guide = import ../lib/fleet-guide.nix;
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf osConfig.cockpit.enable {
        home.file."cockpit/AGENTS.md" = {
          force = true;
          text = guide.system + guide.pilot;
        };
        home.file."cockpit/CLAUDE.md" = {
          force = true;
          text = "@AGENTS.md\n";
        };

        # /launch — deterministic trigger for the "launch the ship" pre-flight
        # described in fleet-guide.nix (the spoken phrase works for any model
        # via AGENTS.md; this makes it a one-keystroke ritual in Claude Code).
        home.file."cockpit/.claude/commands/launch.md" = {
          force = true;
          text = ''
            ---
            description: Pre-flight — orient in the cockpit and report ship status
            ---

            Run the pre-flight ("launch the ship") from AGENTS.md:

            1. Read `~/.claude/projects/-home-max-cockpit/memory/MEMORY.md` and open every
               memory relevant to active or open work.
            2. Run `sudo -n -u fleet-operator fleet status` (standalone, never chained).
            3. Report in a few lines: ship status, drone-fleet health, the open backlog
               and loose ends, and anything time-sensitive. Then hold for a heading from
               the captain — don't start work unprompted.
          '';
        };
      };
    };

  flake.nixosModules.cockpit =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;
    in
    {
      options.cockpit.enable = mkEnableOption "the persistent cockpit session role on this host";

      options.cockpit.webEnvFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          EnvironmentFile holding OPENCODE_SERVER_PASSWORD=<basic-auth pw>
          for the opencode web UI; null = no web UI. The password is a
          second layer on top of tailnet-only reachability (shared-in
          tailnet nodes exist for the Minecraft server, and the ACL that
          confines them is belt-and-braces, not the boundary).
        '';
      };

      config = mkIf config.cockpit.enable {
        # tmux is the session's persistence layer; the binary is already
        # system-wide (packages-shell-utils), this adds the /etc config.
        programs.tmux.enable = true;
        programs.tmux.historyLimit = 50000;

        # The cockpit is where secrets get created/rotated (`agenix -e ...`
        # from the repo root) — fleet credentials in particular originate
        # here (`claude setup-token`, Codex's auth.json).
        environment.systemPackages = singleton inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default;

        # OPENCODE WEB — the cockpit from a phone browser: opencode's bundled
        # server + web UI, running AS the primary user (this is the human's
        # seat — it needs their auth.json, home, and full tooling, so it is
        # deliberately NOT sandboxed or sliced like a tenant service). Binds
        # everywhere; reachability is the fw0 firewall pattern (zero public
        # ports, tailscale0 trusted, br-agents default-drops non-pinhole
        # ports) + the basic-auth password from webEnvFile.
        systemd.services.opencode-web = mkIf (config.cockpit.webEnvFile != null) {
          description = "opencode web UI (tailnet-only cockpit seat)";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          # Agents spawned from web sessions need the same tools a login
          # shell would have: system-wide packages plus the user's own
          # profile (where claude-code/codex/opencode themselves live).
          path = [
            "/run/current-system/sw"
            "/etc/profiles/per-user/${config.primaryUser}"
          ];
          serviceConfig = {
            User = config.primaryUser;
            Group = "users";
            EnvironmentFile = config.cockpit.webEnvFile;
            WorkingDirectory = "/home/${config.primaryUser}/cockpit";
            ExecStart = "${getExe pkgs.opencode} web --hostname 0.0.0.0 --port 4096 --print-logs";
            Restart = "always";
            RestartSec = 3;
          };
        };
      };
    };
}
