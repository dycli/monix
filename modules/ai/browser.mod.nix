# Two Brave MCP servers for the AI seat. kestrel-browser-mcp drives a visible,
# persistent Brave session on a desktop: a user service of the graphical
# session, so it opens on the real desktop rather than growing a second
# display stack, serving MCP over HTTP on loopback. A socket-activated proxy
# shows that port on the tailnet to Water alone (the seat's host), so the
# seat reaches the browser and nothing else on the desktop: no shell, no
# account. kestrel-browser-headless runs a throwaway headless Brave as the
# caller, so the seat browses from inside its own internet-only fence with no
# desktop needed.
{ self, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.agent-browser;
  flake.nixosModules.agent-browser =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe getExe';
      inherit (lib.strings) concatStringsSep;
      inherit (lib.ship) topology;

      # The MCP server's own port, on loopback; the door on the tailnet is
      # topology.browserPort.
      localPort = 8931;
      name = "${config.networking.hostName}.${topology.tailnetDomain}";

      playwrightMcp = import ./playwright-mcp.nix pkgs;

      playwrightArgs = [
        "--browser chrome"
        "--executable-path ${getExe pkgs.brave}"
        "--sandbox"
      ];

      browserMcp = pkgs.writeShellApplication {
        name = "kestrel-browser-mcp";
        runtimeInputs = singleton pkgs.coreutils;
        text = ''
          profile="$HOME/.local/share/kestrel-browser"
          output="$HOME/Downloads/Kestrel"
          install -d -m 0700 "$profile" "$output"

          # The Host header arrives as the proxy's callers send it.
          exec ${getExe playwrightMcp} ${concatStringsSep " " playwrightArgs} \
            --host 127.0.0.1 --port ${toString localPort} \
            --allowed-hosts ${name},${name}:${toString topology.browserPort},localhost \
            --user-data-dir "$profile" \
            --output-dir "$output"
        '';
      };

      headlessMcp = pkgs.writeShellApplication {
        name = "kestrel-browser-headless";
        runtimeInputs = singleton pkgs.coreutils;
        text = ''
          output="$HOME/Downloads/Kestrel"
          install -d -m 0700 "$output"

          exec ${getExe playwrightMcp} ${concatStringsSep " " playwrightArgs} \
            --headless \
            --isolated \
            --output-dir "$output"
        '';
      };
    in
    {
      environment.systemPackages = [
        browserMcp
        headlessMcp
      ];

      # In the session: the graphical environment (Wayland display and the
      # rest) is the user manager's, so the browser opens on the desktop.
      systemd.user.services.kestrel-browser-mcp = {
        description = "The desktop's Brave for the AI seat, as MCP on loopback";
        partOf = singleton "graphical-session.target";
        after = singleton "graphical-session.target";
        wantedBy = singleton "graphical-session.target";
        serviceConfig = {
          ExecStart = getExe browserMcp;
          Restart = "on-failure";
          RestartSec = 3;
        };
      };

      # The door: one port on every interface, which the firewall admits on
      # the tailnet only, and the socket admits from Water only.
      systemd.sockets.kestrel-browser = {
        description = "The desktop's browser MCP, for the seat on Water";
        wantedBy = singleton "sockets.target";
        listenStreams = singleton "0.0.0.0:${toString topology.browserPort}";
        socketConfig = {
          IPAddressAllow = topology.hostTailnetAddr;
          IPAddressDeny = "any";
        };
      };
      systemd.services.kestrel-browser = {
        description = "Relays the browser door to the session's MCP server";
        serviceConfig = lib.ship.hardened.vendor // {
          DynamicUser = true;
          ExecStart = "${getExe' pkgs.systemd "systemd-socket-proxyd"} 127.0.0.1:${toString localPort}";
          IPAddressAllow = [
            "127.0.0.1"
            topology.hostTailnetAddr
          ];
          IPAddressDeny = "any";
        };
      };
    };
}
