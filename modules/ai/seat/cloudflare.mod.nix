# Cloudflare's hosted API MCP server (Code Mode: search and execute over the
# whole API) for the seat, on a read-only account token ("Read all
# resources"): zones, DNS, tunnels, Access, registrar, certificates. The
# clients speak stdio to mcp-proxy, which reads the token from its
# environment, so it stays out of every client config and process argv.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.cloudflare-mcp;
  flake.nixosModules.cloudflare-mcp =
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

      cloudflareMcp = pkgs.writeShellApplication {
        name = "kestrel-cloudflare-mcp";
        runtimeInputs = singleton pkgs.coreutils;
        text = ''
          API_ACCESS_TOKEN=$(tr -d '\r\n' < ${config.secrets.cloudflare-read-token.path})
          export API_ACCESS_TOKEN
          exec ${getExe pkgs.mcp-proxy} --transport streamablehttp --log-level WARNING \
            https://mcp.cloudflare.com/mcp
        '';
      };
    in
    {
      users.groups.cloudflare-read = { };
      users.users.${seat.user}.extraGroups = singleton "cloudflare-read";

      secrets.cloudflare-read-token = {
        file = ../../../hosts/water/secrets/cloudflare-read-token.age;
        group = "cloudflare-read";
        mode = "0440";
      };

      environment.systemPackages = singleton cloudflareMcp;
    };
}
