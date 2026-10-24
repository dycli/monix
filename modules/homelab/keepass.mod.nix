# KeePass sync at https://keepass.<domain>: a WebDAV share the household's
# password apps (Strongbox, KeePassium, Keepass2Android) open their .kdbx
# files from. Tailnet-only like every ship-proxy name. Each person has a
# folder only their login opens, and both open shared/. The databases are
# encrypted by their own master passwords, so these logins only keep the
# files to the household. The nightly NAS backup takes the folder.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.keepass;
  flake.nixosModules.keepass =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) genAttrs;
      inherit (lib.lists) singleton;
      inherit (lib.strings) concatMapStrings;
      dir = "/var/lib/keepass";
      domain = config.shipProxy.domain;

      # bcrypt hashes of random 16-character passwords, safe in the repo.
      logins = {
        dylan = "$2b$12$OVV6Pq4aT2MJvzuMpcBzx.llZXmLHAYdO6xIm5mSUcr/aExnH/zPq";
        gab = "$2b$12$zizi2uXdvRNF6Af9L914xuUbfXuLLNGXap4f3pm.aspAbLBKBvneK";
      };
      passwd =
        name: who:
        pkgs.writeText "keepass-${name}.htpasswd" (concatMapStrings (u: "${u}:${logins.${u}}\n") who);
      folder = name: who: {
        root = dir;
        extraConfig = ''
          auth_basic "KeePass";
          auth_basic_user_file ${passwd name who};
          dav_methods PUT DELETE MKCOL COPY MOVE;
          dav_ext_methods PROPFIND OPTIONS;
          create_full_put_path on;
          dav_access user:rw;
          client_max_body_size 64m;
          client_body_temp_path ${dir}/.part;
          add_header Cache-Control no-store always;
        '';
      };
    in
    {
      services.nginx.additionalModules = singleton pkgs.nginxModules.dav;
      systemd.tmpfiles.settings.keepass =
        genAttrs
          [
            dir
            "${dir}/dylan"
            "${dir}/gab"
            "${dir}/shared"
          ]
          (_: {
            d = {
              user = "nginx";
              group = "nginx";
              mode = "0700";
            };
          });
      systemd.services.nginx.serviceConfig.ReadWritePaths = singleton dir;

      services.nginx.virtualHosts."keepass.${domain}" = {
        useACMEHost = domain;
        forceSSL = true;
        locations = {
          "/".return = "404";
          "/dylan/" = folder "dylan" [ "dylan" ];
          "/gab/" = folder "gab" [ "gab" ];
          "/shared/" = folder "shared" [
            "dylan"
            "gab"
          ];
        };
      };
    };
}
