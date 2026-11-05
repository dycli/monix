# Dylan's Fastmail (mail, calendar, contacts) for the seat, through
# Fastmail's own MCP server, so Bridge's daily chat (Libri) reads mail and
# calendar. Libri holds the sign-in (Settings > Connections, by Fastmail's
# OAuth), renews it, and relays the server to each harness with the current
# token, so no config here holds a secret. Sending is denied in the managed
# settings: the seat drafts, Dylan sends.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.fastmail-mcp;
  flake.nixosModules.fastmail-mcp =
    { lib, ... }:
    let
      inherit (lib.lists) singleton;
    in
    {
      seat.claudeSettings.permissions.deny = singleton "mcp__fastmail__send_email";
    };
}
