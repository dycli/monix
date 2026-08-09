# Brave policies. Linux Chromium resolves through getaddrinfo by default,
# which cannot fetch HTTPS/type-65 records, so ECH keys are never seen;
# forcing the built-in DNS client makes it query them like the other
# platforms. It speaks plain DNS to the system-configured resolver, so
# lookups still flow through the local stub.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.brave;
  flake.nixosModules.brave = {
    environment.etc."brave/policies/managed/dns.json".text = builtins.toJSON {
      BuiltInDnsClientEnabled = true;
    };
  };
}
