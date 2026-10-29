# Dylan's Fastmail (mail, calendar, contacts) for the seat, through
# Fastmail's own MCP server, so Bridge's daily chat (Libri) reads mail and
# calendar. Libri holds the sign-in (Settings > Connections, by Fastmail's
# OAuth), renews it, and relays the server to each harness with the current
# token, so no config here holds a secret. Sending is denied in the managed
# settings: the seat drafts, Dylan sends.
#
# The old agenix token (sokka-fastmail-mcp-token) is no longer read; its
# .age file and its line in the fenced agenix-rules.nix go with Suki's, once
# Suki connects the same way.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.fastmail-mcp;
  flake.nixosModules.fastmail-mcp =
    { lib, ... }:
    let
      inherit (lib.lists) singleton;
    in
    {
      seat.claudeMcp.fastmail = {
        type = "stdio";
        # Libri's development build, as the libri unit runs it, and the
        # unit's state directory, where the sign-in lives.
        command = "/var/lib/libri-build/current/bin/libri";
        args = [
          "fastmail-mcp"
          "/var/lib/libri"
        ];
      };
      seat.claudeSettings.permissions.deny = singleton "mcp__fastmail__send_email";
    };
}
