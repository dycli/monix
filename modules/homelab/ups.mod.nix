# NUT watches the USB-attached UPS and shuts the host down cleanly when the
# battery runs low. Events go to the journal only.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.ups;
  flake.nixosModules.ups =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;
    in
    {
      options.ups.enable = mkEnableOption "NUT monitoring of the USB-attached UPS (probe the hardware first)";

      config = mkIf config.ups.enable {
        # The EcoFlow speaks USB HID PDC.
        power.ups = {
          enable = true;
          mode = "standalone";
          ups.house = {
            driver = "usbhid-ups";
            port = "auto";
            directives = singleton "vendorid = 3746";
          };
          users.upsmon = {
            passwordFile = "/var/lib/nut/upsmon.password";
            upsmon = "primary";
          };
          upsmon.monitor.house = {
            user = "upsmon";
            passwordFile = "/var/lib/nut/upsmon.password";
          };
        };

        system.activationScripts.nut-upsmon-password = ''
          mkdir -p /var/lib/nut
          if [ ! -s /var/lib/nut/upsmon.password ]; then
            # Written to a temp name and renamed, so an interrupted write
            # cannot leave a partial password that then sticks forever.
            (
              umask 077
              tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 \
                > /var/lib/nut/upsmon.password.new
            )
            mv -T /var/lib/nut/upsmon.password.new /var/lib/nut/upsmon.password
          fi
        '';
      };
    };
}
