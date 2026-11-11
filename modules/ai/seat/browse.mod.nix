# OpenCode's browse (anomalyco/browse, MIT): its relay, which lets Libri
# drive the primary user's Brave through browse's extension, installed there
# from the Chrome Web Store. Libri's browser tools use it as their second
# backend, for a task the person allowed their logins for (Libri's
# browser.relay); the harnesses get no browse MCP server of their own, so
# every agent browses through Libri's one tool set and its logins gate.
#
# The relay runs as the seat user on 127.0.0.1:19988, and Brave's extension,
# under the primary user, connects to it there. It admits a browser only
# after pairing: a one-time code from `browse pair` (run as the seat user),
# entered once in the extension's options, is exchanged for a key of the
# browser's own, which both sides prove on every connection. Every HTTP and
# CDP request also needs the token in the seat's
# ~/.local/share/browse/relay-token, so only the seat user's processes drive
# the browser. The pairing lives in the same directory and outlasts restarts.
{ self, ... }:
let
  version = "0.0.13";

  packages = pkgs: {
    cli = pkgs.buildNpmPackage {
      pname = "browse";
      inherit version;
      # The published package: the CLI, relay and MCP server, already bundled.
      # Building the checkout needs Bun and two lockfiles.
      src = pkgs.fetchurl {
        url = "https://registry.npmjs.org/@opencode/browse/-/browse-${version}.tgz";
        hash = "sha512-XKdep+WCWqP/Ddb3bhTjalg7kAa3PPe2/myLgk8iUH598hWvnHJRit8pH/fCFvpxDU1aP2DA9+lHSp55OPMszw==";
      };
      # The tarball ships no lockfile; this one pins the five runtime
      # dependencies. Its build-time dependencies are bundled into dist.
      postPatch = ''
        cp ${./browse/package-lock.json} package-lock.json
        ${pkgs.jq}/bin/jq 'del(.devDependencies, .scripts)' package.json > package.json.new
        mv package.json.new package.json
      '';
      npmDepsHash = "sha256-12PhFrwASIj1xlmhO0Rh5jTjRktqs1i5Kb50tH7fN7Y=";
      dontNpmBuild = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      # Nix owns the version: the relay would otherwise install newer builds
      # from npm on its own, and check for them daily.
      postInstall = ''
        for bin in $out/bin/*; do
          wrapProgram "$bin" \
            --set OPENCODE_BROWSER_AUTO_UPDATE off \
            --set OPENCODE_BROWSER_UPDATE_CHECK 0
        done
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

      systemd.services.browse-relay = {
        description = "Relay from Libri to the primary user's Brave";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment.HOME = seat.home;
        serviceConfig = {
          User = seat.user;
          Group = seat.user;
          ExecStart = "${lib.getExe cli} serve";
          Restart = "on-failure";
          RestartSec = 5;
          # One Node process that holds a WebSocket per side.
          MemoryMax = "512M";
        };
      };
    };
}
