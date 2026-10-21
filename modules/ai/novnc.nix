# websockify and noVNC for the assistants' screens. jwcrypto 1.5.7 rejects
# the short HMAC key in websockify's tests. Drop once the nixpkgs pin
# carries websockify past 0.13.0.
pkgs:
let
  python3 = pkgs.python3.override {
    packageOverrides = _: prev: {
      websockify = prev.websockify.overridePythonAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (pkgs.fetchpatch {
            url = "https://github.com/novnc/websockify/commit/f1e281d2c446380a0a8af7575a92b23ad65c6d4d.patch";
            hash = "sha256-l+j+baTDSEXhOajUKxaT21ET1iEnpiBHwysYnTt3ghk=";
          })
        ];
      });
    };
  };
in
{
  inherit (python3.pkgs) websockify;
  novnc = pkgs.novnc.override { inherit python3; };
}
