# Brave policies and the nsswitch shape Chromium's resolver requires.
#
# Linux Chromium resolves through getaddrinfo by default, which cannot
# fetch HTTPS/type-65 records, so ECH keys are never seen; the policy
# forces the built-in DNS client. That client only activates if every
# hosts service in nsswitch.conf passes Chromium's compatibility check
# (net/dns/dns_config_service_linux.cc), and "mymachines" — added
# unconditionally by the NixOS systemd module — parses as an unknown
# service and fails it. The override drops only that entry; nss-mymachines
# resolves nspawn container names, none of which run on these hosts.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.brave;
  flake.nixosModules.brave =
    { lib, ... }:
    {
      environment.etc."brave/policies/managed/dns.json".text = builtins.toJSON {
        BuiltInDnsClientEnabled = true;
      };

      system.nssDatabases.hosts = lib.mkForce [
        "mdns4_minimal [NOTFOUND=return]"
        "resolve [!UNAVAIL=return]"
        "files"
        "myhostname"
        "dns"
      ];
    };
}
