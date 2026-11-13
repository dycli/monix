# jobmaxxer: Dylan's job catalog. Its nightly pull reads every public job
# source into the catalog the seat already keeps and matches from
# (~/hold/job-search/catalog.sqlite), so it runs as the seat, into that file.
# Matching is an agent job run from Libri; only the pull is a unit.
# Design: github.com/dycli/jobmaxxer, README.
{ inputs, self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.jobmaxxer;
  flake.nixosModules.jobmaxxer =
    { lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship.topology) seat;
    in
    {
      imports = singleton inputs.jobmaxxer.nixosModules.default;

      services.jobmaxxer = {
        enable = true;
        inherit (seat) user;
        database = "${seat.home}/hold/job-search/catalog.sqlite";
      };

      systemd.services.jobmaxxer-pull.unitConfig.RequiresMountsFor = singleton seat.home;
    };
}
