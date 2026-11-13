# hippo2: the seat's memory daemon. One service, running as the seat, reads
# every harness's session logs (Claude Code, Codex, omp, OpenCode, Muse and
# Libri) and files each message word for word into a named memory; every
# harness reads the memories through `hippo2 mcp`, a server in the seat's
# shared list (seat.mod.nix).
# Design: github.com/dycli/hippo2, README.
{ inputs, self, ... }:
{
  # Claude Code and Muse keep their servers in files they also rewrite
  # themselves, so the entry is merged in at activation; omp reads a file of
  # servers alone. Libri's turns pass the shared list on their own.
  flake.homeModules.cockpit =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.strings) escapeShellArg toJSON;

      server = osConfig.seat.mcpServers.hippo2;
      jq = lib.meta.getExe pkgs.jq;

      # `/memory NAME` at a terminal: switches the session's memory by
      # hippo2's memory_use, as Libri's /memory switches a chat's. Each
      # harness reads Markdown commands with `description` front matter and
      # `$ARGUMENTS` from its own folder; Codex lists it as /prompts:memory.
      # omp has a /memory of its own, so it gets none; Pi has no hippo2.
      memoryCommand = ''
        ---
        description: Switch this session's memory (main, tutor, jobs, ...)
        argument-hint: "[memory]"
        ---
        Memory command. If a memory is named here: "$ARGUMENTS", call the
        hippo2 tool `memory_use` with that name now, then say in one line which
        memory this session now reads and files to. If none is named, say in one
        line which memory this session is on, and name the others hippo2 has
        (`hippo2 memories` lists them). Do nothing else.
      '';
    in
    {
      home.file.".omp/agent/mcp.json".force = true;
      home.file.".omp/agent/mcp.json".text = toJSON { mcpServers.hippo2 = server; };

      home.file.".claude/commands/memory.md".text = memoryCommand;
      home.file.".config/opencode/commands/memory.md".text = memoryCommand;
      home.file.".codex/prompts/memory.md".text = memoryCommand;

      home.activation.hippo2Servers = lib.hm.dag.entryAfter (singleton "writeBoundary") ''
        hippo2Server() {
          local file=$1 entry=$2 empty=$3 current next
          current=$(cat "$file" 2>/dev/null || printf '%s' "$empty")
          if printf '%s' "$current" | ${jq} -e --argjson s "$entry" '.mcpServers.hippo2 == $s' >/dev/null; then
            return 0
          fi
          next=$(printf '%s' "$current" | ${jq} --argjson s "$entry" '.mcpServers.hippo2 = $s') || return 1
          if [[ -v DRY_RUN ]]; then
            echo "would add hippo2 to $file"
            return 0
          fi
          mkdir -p "$(dirname "$file")"
          (umask 077 && printf '%s\n' "$next" > "$file.hippo2")
          if [ -e "$file" ]; then chmod --reference="$file" "$file.hippo2"; fi
          mv "$file.hippo2" "$file"
        }
        hippo2Server "$HOME/.claude.json" ${escapeShellArg (toJSON server)} '{}'
        hippo2Server "''${XDG_CONFIG_HOME:-$HOME/.config}/muse/settings.json" ${
          escapeShellArg (
            toJSON (
              server
              // {
                env = { };
                # A server that fails to start never blocks Muse.
                mode = "optional";
              }
            )
          )
        } '{"schema_version": 1}'
      '';
    };

  flake.nixosModules.seat = self.nixosModules.hippo2;
  flake.nixosModules.hippo2 =
    { lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship.topology) seat;
    in
    {
      imports = singleton inputs.hippo2.nixosModules.default;

      services.hippo2 = {
        enable = true;
        inherit (seat) user;
        dataDir = seat.hippo2;
        # Evaluation runs and probes keep out of the main memory.
        directoryMemories = {
          "${seat.home}/ark/hippo-climb" = "trial";
          "/tmp" = "trial";
        };
      };

      systemd.services.hippo2.unitConfig.RequiresMountsFor = [
        "/srv/storage"
        seat.home
      ];
      # SQLite needs a live database's WAL index writable even to read it.
      systemd.services.hippo2.serviceConfig.ReadWritePaths =
        singleton "-${seat.home}/.local/share/opencode";
    };
}
