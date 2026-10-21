# eMudhra generated the keys of eight intermediates under these two roots so
# badly that anyone can recover them (disclosed 2026-10-20). NSS 3.131.1
# distrusts them; remove this once nixpkgs' cacert is at least that.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.pki;
  flake.nixosModules.pki = {
    security.pki.caCertificateBlacklist = [
      "Comodo AAA Services root"
      "emSign ECC Root CA - G3"
    ];
  };
}
