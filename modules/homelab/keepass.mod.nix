# KeePass sync at https://pass.<domain>: a WebDAV share Gab's password
# app (Strongbox, KeePassium) opens her .kdbx from. Tailnet-only like every
# ship-proxy name, behind one login. The database is encrypted by her own
# master password, so the login only keeps the file to the household. The
# nightly NAS backup takes the folder.
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
      inherit (lib.lists) singleton;
      dir = "/var/lib/keepass";
      domain = config.shipProxy.domain;

      # bcrypt hash of a random 16-character password, safe in the repo.
      passwd = pkgs.writeText "keepass.htpasswd" ''
        gab:$2b$12$zizi2uXdvRNF6Af9L914xuUbfXuLLNGXap4f3pm.aspAbLBKBvneK
      '';
    in
    {
      services.nginx.additionalModules = singleton pkgs.nginxModules.dav;
      systemd.tmpfiles.settings.keepass.${dir}.d = {
        user = "nginx";
        group = "nginx";
        mode = "0700";
      };
      systemd.services.nginx.serviceConfig.ReadWritePaths = singleton dir;

      services.nginx.virtualHosts."pass.${domain}" = {
        useACMEHost = domain;
        forceSSL = true;
        locations."/" = {
          root = dir;
          extraConfig = ''
            auth_basic "KeePass";
            auth_basic_user_file ${passwd};
            dav_methods PUT DELETE MKCOL COPY MOVE;
            dav_ext_methods PROPFIND OPTIONS;
            create_full_put_path on;
            dav_access user:rw;
            client_max_body_size 64m;
            client_body_temp_path ${dir}/.part;
            add_header Cache-Control no-store always;
          '';
        };
      };
    };
}
