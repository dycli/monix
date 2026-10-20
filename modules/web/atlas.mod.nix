# The atlas at https://atlas.<domain>: a visual map of everything in the git
# mirror, drawn to scale. The site is built here; the data it draws is
# written by `atlas-scan` every hour from the mirror, plus what Nix knows
# about monix (hosts, services, routes, which module configures which),
# evaluated at build time by atlas/extract.nix. The guided tours live in
# atlas/tours.toml, and a check fails the build when a tour names a file
# that is gone.
{ self, lib, ... }:
let
  # Evaluated from every host, so it changes with each commit to monix.
  system =
    pkgs:
    pkgs.writeText "atlas-system.json" (
      lib.strings.toJSON (import ./atlas/extract.nix { inherit lib self; })
    );
in
{
  flake.nixosModules.lab = self.nixosModules.atlas;
  flake.nixosModules.atlas =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.ship) hardened;

      dir = "/var/lib/atlas";
      mirror = "/srv/storage/git";

      site = pkgs.buildNpmPackage {
        pname = "atlas-site";
        version = "0";
        src = ./atlas/site;
        npmDepsHash = "sha256-zVQpbLosRBW/xU3pMRPPooTHrQ05sP4DRDSJf45v9Fk=";
        # rolldown and tsgo ship prebuilt Linux binaries.
        nativeBuildInputs = singleton pkgs.autoPatchelfHook;
        buildInputs = singleton pkgs.stdenv.cc.cc.lib;
        installPhase = "cp -r dist $out";
      };
    in
    # The scan reads the mirror, so the atlas lives where the mirror does.
    mkIf (config.gitMirror.tokenFile != null) {
      shipProxy.routes.atlas.root = "${site}";
      services.nginx.virtualHosts."atlas.${config.shipProxy.domain}".locations."/data/" = {
        alias = "${dir}/data/";
        extraConfig = "add_header Cache-Control no-cache;";
      };

      users.users.atlas = {
        isSystemUser = true;
        group = "atlas";
        extraGroups = singleton "git-mirror";
      };
      users.groups.atlas = { };
      # nginx reads the data through the group; setgid passes it to new files.
      systemd.tmpfiles.settings.atlas = {
        ${dir}.d = {
          user = "atlas";
          group = "nginx";
          mode = "2750";
        };
        "${dir}/data".d = {
          user = "atlas";
          group = "nginx";
          mode = "2750";
        };
      };

      systemd.services.atlas-scan = {
        description = "Draw the atlas from the git mirror";
        # Each deploy changes the system data, so the switch redraws it too.
        wantedBy = singleton "multi-user.target";
        after = [
          "srv-storage.mount"
          "git-mirror.service"
        ];
        unitConfig.RequiresMountsFor = mirror;
        path = singleton pkgs.git;
        serviceConfig = hardened.tenant // {
          Type = "oneshot";
          User = "atlas";
          Group = "atlas";
          ExecStart = "${pkgs.python3}/bin/python3 -I ${./atlas/atlas.py} scan --mirrors ${mirror} --system ${system pkgs} --out ${dir}/data/atlas.json --cache ${dir}/cache";
          ReadWritePaths = singleton dir;
          ReadOnlyPaths = singleton mirror;
          UMask = "0027";
          Nice = 15;
          IOSchedulingClass = "idle";
          # It reads local files only.
          IPAddressDeny = "any";
        };
      };
      systemd.timers.atlas-scan = {
        wantedBy = singleton "timers.target";
        timerConfig = {
          OnCalendar = "hourly";
          Persistent = true;
        };
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      checks.atlas-tours = pkgs.runCommand "atlas-tours" { } ''
        ${pkgs.python3}/bin/python3 -I ${./atlas/atlas.py} check \
          --tree ${self} --tours ${./atlas/tours.toml} --system ${system pkgs}
        touch $out
      '';
    };
}
