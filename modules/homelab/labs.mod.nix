# Private labs at https://labs.<domain>: small projects that stay on the
# tailnet, beside the public ones at su.is/labs/ on Air. Each project sits
# under its own path (/freedom); ~/hold/sites/labs/deploy copies the source
# tree into the served directory.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.labs;
  flake.nixosModules.labs =
    { lib, ... }:
    let
      dir = "/var/lib/labs";
    in
    {
      shipProxy.routes.labs.root = dir;
      systemd.tmpfiles.settings.labs.${dir}.d = {
        user = lib.ship.topology.seat.user;
        group = "nginx";
        mode = "2750";
      };
    };
}
