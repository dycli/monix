# A local subscription-value ledger for the cockpit's Claude and ChatGPT
# pools. Collection is periodic because source CLIs may prune their logs.
{ self, ... }:
{
  flake.homeModules.lab = self.homeModules.ship-costs;
  flake.homeModules.ship-costs =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;

      isBridge = config.home.username == "bridge";
      shipCosts = pkgs.rustPlatform.buildRustPackage {
        pname = "ship-costs";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./ship-costs;
          filter = path: type: type != "directory" || !lib.strings.hasSuffix "/target" (toString path);
        };
        cargoLock.lockFile = ./ship-costs/Cargo.lock;
        env.SHIP_COSTS_FLEET_DIR = "/var/lib/agents/tasks";
        meta.mainProgram = "ship-costs";
      };
    in
    {
      home.packages = mkIf isBridge (singleton shipCosts);

      systemd.user.services.ship-costs-collect = mkIf isBridge {
        Unit.Description = "Collect local AI subscription usage";
        Service = {
          Type = "oneshot";
          ExecStart = "${getExe shipCosts} collect --quiet";
        };
      };

      systemd.user.timers.ship-costs-collect = mkIf isBridge {
        Unit.Description = "Preserve local AI subscription usage";
        Timer = {
          OnBootSec = "10m";
          OnUnitActiveSec = "15m";
          Persistent = true;
        };
        Install.WantedBy = singleton "timers.target";
      };
    };
}
