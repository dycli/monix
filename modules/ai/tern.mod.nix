# Tern (Stencil), closed beta: terminal workspace with a daemon, remote hosts
# over Tailscale and a phone client. Its download sits behind a Stencil
# sign-in, so Nix cannot fetch it: requireFile takes the tarball Dylan
# downloaded, added once to the store with
#   nix-store --add-fixed sha256 Tern-0.9.12-linux-x86_64.tar.gz
# A public, pinnable download URL removes this step.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.tern;
  flake.nixosModules.tern =
    { pkgs, lib, ... }:
    let
      tern = pkgs.stdenv.mkDerivation {
        pname = "tern";
        version = "0.9.12";
        src = pkgs.requireFile {
          name = "Tern-0.9.12-linux-x86_64.tar.gz";
          url = "https://build.stencil.so/tern";
          sha256 = "f67e8c2bff437f3365ae3a478bbc18f63afb6e53bd6e7cd556bac7ce24d13693";
        };
        sourceRoot = "tern";
        nativeBuildInputs = lib.lists.singleton pkgs.autoPatchelfHook;
        buildInputs = lib.lists.singleton pkgs.stdenv.cc.cc.lib;
        # The window and remote logins (libpam) open through libraries Tern
        # loads by name at run time (dlopen), which autoPatchelf cannot see;
        # runtimeDependencies adds them to the binary's search path.
        runtimeDependencies = [
          pkgs.linux-pam
          pkgs.wayland
          pkgs.libxkbcommon
          pkgs.vulkan-loader
          pkgs.libglvnd
        ];
        installPhase = "install -Dm755 tern $out/bin/tern";
        meta.license = lib.licenses.unfree;
      };
    in
    {
      # Sessions run as bridge, so the agents' sign-ins and clutter stay out
      # of Dylan's home. The system service (root, logins through PAM) lets
      # a tailnet login act as a local user without SSH keys. katara's own
      # `tern remote serve --user` keeps UDP 8376, so this one takes 8377.
      # tailscale = true is safe here: tailscale0 is the only interface the
      # firewall trusts, so only tailscaled delivers tailnet addresses.
      environment.etc."tern/access.toml".text = ''
        tailscale = true

        [[allow]]
        method = "tailscale"
        identity = "ddcleary1@gmail.com"
        users = ["bridge"]
      '';
      # Tern opens each session through PAM (account and session stages,
      # no password step), under the service name "tern".
      security.pam.services.tern = { };
      systemd.services.tern-remote = {
        description = "Tern remote sessions";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "tailscaled.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = "${tern}/bin/tern remote serve --listen 0.0.0.0:8377 --state-dir /var/lib/tern --access /etc/tern/access.toml";
          StateDirectory = "tern";
          StateDirectoryMode = "0700";
          Restart = "on-failure";
        };
      };

      # requireFile marks the tarball itself unfree, named "Tern".
      unfreePackages = [
        "tern"
        "Tern"
      ];
      environment.systemPackages = [
        tern
        # The tarball ships no icon or desktop file.
        (pkgs.makeDesktopItem {
          name = "tern";
          desktopName = "Tern";
          comment = "Terminal workspace";
          exec = "${tern}/bin/tern %U";
          icon = "utilities-terminal";
          categories = [
            "System"
            "TerminalEmulator"
          ];
        })
      ];
    };
}
