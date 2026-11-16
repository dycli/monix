# OpenCode's browse (anomalyco/browse, MIT): agents use the primary user's
# own Brave, with its sign-ins, through browse's extension, installed there
# from the Chrome Web Store. A convenience beside Libri, not part of it:
# Libri's own browser tools run its built-in browser alone, and the harnesses
# reach Brave through browse's own MCP server (`browse mcp`), which the seat
# hands them as it hands them its other servers. Which harnesses get it is
# `seat.extraMcpServers.browse.agents` (seat.mod.nix); every one by default.
# It acts in Dylan's logged-in Brave, so narrowing that narrows who can.
#
# The relay runs as the seat user on 127.0.0.1:19988, and Brave's extension,
# under the primary user, connects to it there. It admits a browser only
# after pairing: a one-time code from `browse pair` (run as the seat user),
# entered once in the extension's options, is exchanged for a key of the
# browser's own, which both sides prove on every connection. Every request
# also needs the token in the seat's ~/.local/share/browse/relay-token, so
# only the seat user's processes drive the browser. The pairing lives in the
# same directory and outlasts restarts and upgrades.
#
# The seat's slice denies loopback (seat.mod.nix), so the server reaches the
# relay from Libri's turns and terminals, not from an SSH session.
{ self, ... }:
let
  version = "0.1.0";

  packages = pkgs: {
    cli = pkgs.rustPlatform.buildRustPackage {
      pname = "browse";
      inherit version;
      # One native binary since 0.1.0: the CLI, the relay and the MCP server.
      src = pkgs.fetchFromGitHub {
        owner = "anomalyco";
        repo = "browse";
        tag = "v${version}";
        hash = "sha256-5AKN01QsquK7XmaGSo7eiFbUcus2Q+teO+++7qReUbw=";
      };
      sourceRoot = "source/rust";
      cargoHash = "sha256-RC27sSYrjnCFN6CpNnO0QPRxTleBPrGQRWEwg4USLVI=";
      cargoBuildFlags = [
        "--package"
        "browse"
      ];
      # These run npm, Bun, pnpm and Yarn global installs that update browse
      # by curl; Nix owns its updates (below), and the sandbox has neither.
      checkFlags = [
        "--skip=npm_global_install"
        "--skip=bun_global_install"
        "--skip=pnpm_global_install"
        "--skip=yarn_global_install"
      ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      # Nix owns the version and systemd the relay. Without these the binary
      # would install newer builds on its own and check for them daily, and
      # the MCP server, finding no relay, would start one of its own, on a
      # free port of its choosing when 19988 is taken.
      postInstall = ''
        wrapProgram $out/bin/browse \
          --set OPENCODE_BROWSER_AUTO_UPDATE off \
          --set OPENCODE_BROWSER_UPDATE_CHECK 0 \
          --set OPENCODE_BROWSER_AUTOSTART 0 \
          --set OPENCODE_BROWSER_PORT 19988
      '';
      meta.mainProgram = "browse";
    };
  };
in
{
  flake.nixosModules.seat = self.nixosModules.browse;
  flake.nixosModules.browse =
    { lib, pkgs, ... }:
    let
      inherit (lib.ship.topology) seat;
      cli = (packages pkgs).cli;
    in
    {
      # `browse pair` and `browse status`, run as the seat user.
      environment.systemPackages = [ cli ];

      seat.extraMcpServers.browse.server = {
        command = lib.getExe cli;
        args = [ "mcp" ];
      };

      systemd.services.browse-relay = {
        description = "Relay from the seat's agents to the primary user's Brave";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment.HOME = seat.home;
        serviceConfig = {
          User = seat.user;
          Group = seat.user;
          ExecStart = "${lib.getExe cli} serve";
          Restart = "on-failure";
          RestartSec = 5;
          MemoryMax = "512M";
        };
      };
    };
}
