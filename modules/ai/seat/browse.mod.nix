# OpenCode's browse (anomalyco/browse, MIT): a `browse` MCP server that drives
# a Chromium through an extension and a local relay. The seat's harnesses get
# it beside their other servers (seat.mod.nix); the MCP server starts the
# relay on 127.0.0.1:19988 as the seat user.
#
# The browser is the seat's own: a headless Chromium under the seat user with
# a profile of its own in the seat's home, never the primary user's Brave.
# Water's desktop session starts only on a local login, so a browser there
# would be absent most of the time. Headless means no handoffs: a login or
# 2FA an agent cannot do itself waits for a headed browser.
#
# The relay admits a browser only after pairing: a one-time code, exchanged
# for a key of the browser's own, which both sides prove on every connection.
# Pairing this browser is done once, by running browse-pair as the seat user.
# Every HTTP and CDP request also needs the token in the seat's
# ~/.local/share/browse/relay-token.
{ self, ... }:
let
  version = "0.0.13";

  packages = pkgs: rec {
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

    # The release's store zip, with the manifest key the store build drops put
    # back (public/manifest.json at v${version}; a public key, browse/manifest-key.json): unpacked, it then has the ID
    # afeafocngkodbmaipcngoamamfmekgfo, one of the two the relay accepts.
    extension = pkgs.stdenvNoCC.mkDerivation {
      pname = "browse-extension";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/anomalyco/browse/releases/download/v${version}/opencode-browser-${version}.zip";
        hash = "sha256-btcx4A5e4Pr3NNMl8hMs9lhhSOGaNKL4oT994hKPpw4=";
      };
      nativeBuildInputs = [
        pkgs.unzip
        pkgs.jq
      ];
      sourceRoot = ".";
      installPhase = ''
        mkdir -p $out
        cp -r . $out
        jq --arg key ${pkgs.lib.strings.escapeShellArg (builtins.fromJSON (builtins.readFile ./browse/manifest-key.json)).key} \
          '.key = $key' manifest.json > $out/manifest.json
      '';
    };

    # Chromium loads the extension from a writable copy in the seat's home:
    # pairing drops a one-time code into the unpacked folder (browse-pair),
    # which the store path cannot take.
    chromium = pkgs.writeShellApplication {
      name = "browse-chromium";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        root="$HOME/.local/share/browse"
        rm -rf "$root/extension"
        mkdir -p "$root"
        cp -r --no-preserve=mode ${extension} "$root/extension"
        exec ${pkgs.lib.meta.getExe pkgs.chromium} \
          --headless=new \
          --user-data-dir="$root/chromium" \
          --load-extension="$root/extension" \
          --disable-extensions-except="$root/extension" \
          --no-first-run --no-default-browser-check \
          "$@"
      '';
    };

    # Pairs the running browse-chromium with the relay, once, as the seat
    # user: mints a one-time code and drops it where the extension looks for
    # it; the extension keeps checking until it appears.
    pair = pkgs.writeShellApplication {
      name = "browse-pair";
      runtimeInputs = [
        cli
        pkgs.coreutils
        pkgs.gnugrep
      ];
      text = ''
        root="$HOME/.local/share/browse"
        log=$(mktemp)
        trap 'rm -f "$log" "$root/extension/relay-pairing.json"' EXIT
        browse pair --wait-seconds 120 > "$log" 2>&1 &
        code=""
        for _ in $(seq 30); do
          code=$(grep -oE '[0-9A-Z]{4}-[0-9A-Z]{4}' "$log" | head -1 || true)
          [ -n "$code" ] && break
          sleep 1
        done
        [ -n "$code" ] || { cat "$log"; exit 1; }
        printf '{"code":"%s"}' "$code" > "$root/extension/relay-pairing.json"
        wait
        cat "$log"
      '';
    };
  };
in
{
  flake.nixosModules.seat = self.nixosModules.browse;
  flake.nixosModules.browse =
    {
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.ship) fences topology;
      inherit (topology) seat;
      browse = packages pkgs;
    in
    {
      environment.systemPackages = [
        browse.cli
        browse.chromium
        browse.pair
      ];

      systemd.services.browse-chromium = {
        description = "The seat's headless Chromium for browse";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          User = seat.user;
          Group = seat.user;
          ExecStart = lib.meta.getExe browse.chromium;
          Restart = "always";
          RestartSec = 10;
          # The seat's own fence: the internet and the relay on 127.0.0.1,
          # not the LAN or the tailnet.
          IPAddressDeny = fences.internetOnlyDeny;
        };
      };
    };
}
