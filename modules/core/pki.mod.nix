# eMudhra generated the keys of eight intermediates under this root so badly
# that anyone can recover them (disclosed 2026-10-20). NSS 3.131.1 dropped the
# emSign root beside it, and cacert fails on a blacklisted name it lacks, but
# still ships this one; remove this once nixpkgs' cacert drops it too.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.pki;
  flake.nixosModules.pki = {
    security.pki.caCertificateBlacklist = [
      "Comodo AAA Services root"
    ];
  };
}
