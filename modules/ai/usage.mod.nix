# usage: every subscription's limits (Claude, ChatGPT/Codex, OpenCode Go),
# read live from each provider on each connection to /run/usage.sock and
# never stored. The seat's `usage` and the household assistants' `usage`
# tool both read it; only this service sees the logins. Claude's usage
# endpoint takes only a full login, so it reads the seat's, which the seat
# keeps fresh, and never renews it; Codex runs on the household login
# (sokka.mod.nix) and renews that itself. Undocumented endpoints; expect
# them to change.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.usage;
  flake.nixosModules.usage =
    { lib, pkgs, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.ship) fences;

      inherit (lib.ship.topology) seat;

      report = pkgs.writers.writePython3Bin "usage-report" {
        flakeIgnore = singleton "E501";
      } (builtins.readFile ./usage.py);
    in
    {
      users.groups.usage = { };
      users.users.${seat.user}.extraGroups = singleton "usage";

      systemd.sockets.usage = {
        description = "Subscription limits";
        wantedBy = singleton "sockets.target";
        socketConfig = {
          ListenStream = "/run/usage.sock";
          Accept = true;
          MaxConnections = 4;
          SocketMode = "0660";
          SocketGroup = "usage";
        };
      };

      systemd.services."usage@" = {
        description = "One subscription-limits report";
        path = singleton pkgs.codex;
        environment = {
          HOME = "/var/lib/sokka-image";
          CODEX_HOME = "/var/lib/sokka-image";
        };
        serviceConfig = lib.ship.hardened.tenant // {
          User = "sokka-image";
          Group = "sokka-image";
          StateDirectory = "sokka-image";
          StateDirectoryMode = "0700";
          LoadCredential = [
            "claude:${seat.home}/.claude/.credentials.json"
            "opencode:${seat.home}/.local/share/opencode/auth.json"
          ];
          ExecStart = getExe report;
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
          IPAddressAllow = fences.loopback;
          IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          # Hides the seat's Codex config and its MCP servers.
          BindReadOnlyPaths = singleton "${pkgs.emptyDirectory}:/etc/codex";
        };
      };
    };
}
