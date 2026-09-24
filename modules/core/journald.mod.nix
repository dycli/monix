# journald's default cap is 10% of the filesystem, up to 4G. 1G is months
# of history here.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.journald;
  flake.nixosModules.journald =
    { lib, ... }:
    {
      services.journald.settings.Journal.SystemMaxUse = lib.modules.mkDefault "1G";
    };
}
