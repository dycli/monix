# System fonts. The Comic Code install is gated on its ciphertext existing, so
# hosts without it fall through to CaskaydiaMono in the monospace list.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.fonts;
  flake.nixosModules.fonts =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf mkMerge;

      # Comic Code is paid, so the repo carries only agenix ciphertext of a
      # gzipped tar; the store is world-readable and world-copyable, so the
      # font is decrypted to /var/lib at activation rather than a store path:
      #
      #   tar czf /tmp/comic-code.tgz -C <dir containing the .otf files> .
      #   cd ~/ark/monix && EDITOR="cp /tmp/comic-code.tgz" agenix -e assets/fonts/comic-code.age
      #   git add assets/fonts/comic-code.age && rm /tmp/comic-code.tgz
      comicCodeAge = ../../assets/fonts/comic-code.age;
      hasComicCode = lib.pathExists comicCodeAge;
    in
    {
      config = mkMerge [
        (mkIf hasComicCode {
          secrets.comic-code.file = comicCodeAge;

          system.activationScripts.comic-code-fonts = {
            deps = [ "agenixInstall" ];
            text = ''
              rm -rf /var/lib/fonts/comic-code
              mkdir -p /var/lib/fonts/comic-code
              # Activation runs with a minimal PATH, so tar cannot find a
              # gzip to shell out to; the store path is passed explicitly
              ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
                -xf "${config.secrets.comic-code.path}" -C /var/lib/fonts/comic-code
              chmod -R a+rX /var/lib/fonts/comic-code
            '';
          };

          # fonts.packages takes only store paths, so the decrypted directory
          # is given to fontconfig directly.
          fonts.fontconfig.localConf = ''
            <?xml version="1.0"?>
            <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
            <fontconfig>
              <dir>/var/lib/fonts</dir>
            </fontconfig>
          '';
        })
        {
          fonts.enableDefaultPackages = true;

          fonts.packages = [
            pkgs.noto-fonts
            pkgs.noto-fonts-color-emoji
            pkgs.nerd-fonts.caskaydia-mono
          ];

          fonts.fontconfig.defaultFonts = {
            monospace = [
              "ComicCodeLigatures Nerd Font"
              "CaskaydiaMono Nerd Font"
            ];
            sansSerif = [ "Noto Sans" ];
            serif = [ "Noto Serif" ];
            emoji = [ "Noto Color Emoji" ];
          };
        }
      ];
    };
}
