# Dylan's Fastmail (mail, calendar, contacts) for the seat, through
# Fastmail's own MCP server on the token Sokka holds, so Bridge's daily chat
# (Libri) reads mail and calendar as Sokka does. As in cloudflare.mod.nix,
# mcp-proxy reads the token from its environment, keeping it out of every
# client config and process argv. Sending is denied in the managed settings:
# the seat drafts, Dylan sends.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.fastmail-mcp;
  flake.nixosModules.fastmail-mcp =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.ship.topology) seat;

      fastmailMcp = pkgs.writeShellApplication {
        name = "kestrel-fastmail-mcp";
        runtimeInputs = singleton pkgs.coreutils;
        text = ''
          API_ACCESS_TOKEN=$(tr -d '\r\n' < ${config.secrets.sokka-fastmail-mcp-token.path})
          export API_ACCESS_TOKEN
          exec ${getExe pkgs.mcp-proxy} --transport streamablehttp --log-level WARNING \
            https://api.fastmail.com/mcp
        '';
      };
    in
    {
      users.groups.fastmail-dylan = { };
      users.users.${seat.user}.extraGroups = singleton "fastmail-dylan";

      # Sokka's unit takes it as a systemd credential, read as root, so the
      # group changes nothing for Sokka.
      secrets.sokka-fastmail-mcp-token = {
        file = ../../../hosts/water/secrets/sokka-fastmail-mcp-token.age;
        group = "fastmail-dylan";
        mode = "0440";
      };

      environment.systemPackages = singleton fastmailMcp;

      seat.claudeMcp.fastmail = {
        type = "stdio";
        command = "/run/current-system/sw/bin/kestrel-fastmail-mcp";
        args = [ ];
      };
      seat.claudeSettings.permissions.deny = singleton "mcp__fastmail__send_email";
    };
}
