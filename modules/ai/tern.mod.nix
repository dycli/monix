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
        # The window opens through libraries Tern loads by name at run time
        # (dlopen), which autoPatchelf cannot see; runtimeDependencies adds
        # them to the binary's search path.
        runtimeDependencies = [
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
      # requireFile marks the tarball itself unfree, named "Tern".
      unfreePackages = [
        "tern"
        "Tern"
      ];
      environment.systemPackages = lib.lists.singleton tern;
    };
}
