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
    let
      source = (lib.importJSON ../../../_sources/generated.json).brave;
      inherit (lib.generators) toJSON;
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkForce;
    in
    {
      nixpkgs.overlays = singleton (
        # Brave left nixpkgs on 2026-11-03, so it is built here from Brave's
        # own .deb at the version nvfetcher pinned in _sources/.
        final: _: {
          brave = final.callPackage (import ./make-brave.nix ({
            pname = "brave";
            inherit (source) version;
            archives.x86_64-linux = {
              inherit (source.src) url;
              hash = source.src.sha256;
            };

            optStem = "brave";
            fileStem = "brave-browser";
            appIdStem = "com.brave.Browser";
            darwinStem = "Brave Browser";
            changelogFile = "CHANGELOG_DESKTOP.md";
            homepage = "https://brave.com/";
            innerBinary = "brave";
          })) { commandLineArgs = "--hide-crash-restore-bubble"; };
        }
      );

      environment.etc."brave/policies/managed/monix.json".text = toJSON { } (
        import ./policies.nix
        // {
          # ECH: the built-in client fetches HTTPS/type-65 records; the pin
          # guards against upstream default changes. macOS Chromium uses its
          # built-in client already.
          BuiltInDnsClientEnabled = true;
          EncryptedClientHelloEnabled = true;
        }
      );

      system.nssDatabases.hosts = mkForce [
        "mdns4_minimal [NOTFOUND=return]"
        "resolve [!UNAVAIL=return]"
        "files"
        "myhostname"
        "dns"
      ];
    };

  # macOS takes Brave's own signed app, which updates itself. Brave reads
  # forced policies only from managed preferences, which macOS rebuilds from
  # installed configuration profiles and clears of anything else, and it
  # installs a profile only with an administrator's approval in System
  # Settings. So the switch places the profile, and approving it is a manual
  # step after each policy change. The profile is device-scope: it applies
  # to every account's Brave. The fixed identifier and UUIDs make an approved
  # profile replace its predecessor rather than sit beside it.
  flake.darwinModules.desktop = self.darwinModules.brave-darwin;
  flake.darwinModules.brave-darwin =
    { lib, ... }:
    let
      inherit (lib.generators) toPlist;
      inherit (lib.lists) singleton;
    in
    {
      homebrew.casks = singleton "brave-browser";

      environment.etc."brave/brave-policies.mobileconfig".text = toPlist { escape = true; } {
        PayloadType = "Configuration";
        PayloadVersion = 1;
        PayloadScope = "System";
        PayloadIdentifier = "monix.brave-policies";
        PayloadUUID = "8291A04B-D810-4778-8150-DBE1B7753742";
        PayloadDisplayName = "Brave policies";
        PayloadDescription = "The Brave policies monix sets on every desktop.";
        PayloadContent = singleton (
          import ./policies.nix
          // {
            PayloadType = "com.brave.Browser";
            PayloadVersion = 1;
            PayloadIdentifier = "monix.brave-policies.com.brave.Browser";
            PayloadUUID = "F693A69B-BDDD-4B95-BBE7-2571B2CF59BF";
            PayloadDisplayName = "Brave";
          }
        );
      };
    };
}
