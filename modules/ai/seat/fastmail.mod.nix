# Dylan's Fastmail (mail, calendar, contacts) for the seat, through
# Fastmail's own MCP server, so Bridge's daily chat reads mail and calendar.
# `libri-connect` holds the OAuth sign-in in `/var/lib/libri/connections`,
# `libri-connect-renew.timer` renews it, and `libri-connect serve fastmail`
# relays the server under the MCP name `fastmail` with core approval prompts,
# so no config here holds a secret. Sending is denied in the managed
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
