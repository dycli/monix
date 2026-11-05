# libri-publish: puts what Water has live on Libri's Cloudflare Workers, so
# neither goes stale (app.libri.is did, 11-05, while published by hand):
# libri.is with every Android release at /android/, and app.libri.is with
# the seat's live site build. publish_libri_sites.sh beside this file holds
# the logic; the Workers' configs and libri.is's script sit in
# libri-publish/.
#
# - It runs after each Libri deploy (libri-deploy's OnSuccess, which an
#   already-live commit also triggers, harmlessly) and after each Android
#   publish (libri-publish-android starts it; polkit lets the seat start
#   this unit and do nothing else to it).
# - The Cloudflare token is root's: systemd hands it to this unit alone as a
#   credential, and the unit runs as a user of its own, so the seat and its
#   workers, which share the seat's uid, never hold it.
# - The release folder belongs to the seat and this unit's group; its APKs
#   are world-readable, and Worker static assets take files up to 25 MiB.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.libri-publish;
  flake.nixosModules.libri-publish =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship) fences;
      inherit (lib.ship.topology) seat;

      state = "/var/lib/libri-publish";
      publish = pkgs.writeShellApplication {
        name = "libri-publish";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.wrangler
        ];
        text = ''
          exec sh ${./libri-publish}/publish_libri_sites.sh
        '';
      };
    in
    {
      users.users.libri-publish = {
        isSystemUser = true;
        group = "libri-publish";
      };
      users.groups.libri-publish = { };

      # A token able to deploy libri-is-site and libri-app, raw.
      secrets.libri-publish-cloudflare-token.file = ../../../hosts/water/secrets/libri-publish-cloudflare-token.age;

      # The seat copies each signed release here (libri-publish-android).
      systemd.tmpfiles.settings.libri-android."/var/lib/libri-android".d = {
        user = seat.user;
        group = "libri-publish";
        mode = "2750";
      };

      systemd.services.libri-deploy.onSuccess = singleton "libri-publish.service";

      systemd.services.libri-publish = {
        description = "Publish Libri's live build to libri.is and app.libri.is";
        restartIfChanged = false;
        environment = {
          HOME = state;
          XDG_CONFIG_HOME = "${state}/config";
          LIBRI_PUBLISH_DIR = "${state}/stage";
          LIBRI_ANDROID_DIR = "/var/lib/libri-android";
          LIBRI_PUBLISH_SITE = "${seat.libriBuild}/site";
          # Not a secret: the account the Workers belong to.
          CLOUDFLARE_ACCOUNT_ID = "fd36658954c6a4df540bc3975d993ba2";
        };
        serviceConfig = lib.ship.hardened.tenant // {
          Type = "oneshot";
          User = "libri-publish";
          Group = "libri-publish";
          StateDirectory = "libri-publish";
          StateDirectoryMode = "0700";
          LoadCredential = singleton "cloudflare:${config.secrets.libri-publish-cloudflare-token.path}";
          ExecStart = lib.meta.getExe publish;
          # The seat's home holds nothing this needs.
          ProtectHome = true;
          IPAddressDeny = fences.internetOnlyDeny;
          # Every APK goes up when Cloudflare holds none of them.
          TimeoutStartSec = "30min";
        };
      };

      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "libri-publish.service" &&
              action.lookup("verb") == "start" &&
              subject.user == "${seat.user}") {
            return polkit.Result.YES;
          }
        });
      '';
    };
}
