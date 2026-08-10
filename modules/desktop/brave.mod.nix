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
      inherit (lib.generators) toJSON;
      inherit (lib.modules) mkForce;
    in
    {
      environment.etc."brave/policies/managed/monix.json".text = toJSON { } {
        # ECH: the built-in client fetches HTTPS/type-65 records; the pin
        # guards against upstream default changes.
        BuiltInDnsClientEnabled = true;
        EncryptedClientHelloEnabled = true;

        # Brave surface reduction.
        BraveRewardsDisabled = true;
        BraveWalletDisabled = true;
        BraveVPNDisabled = true;
        TorDisabled = true;
        BraveAIChatEnabled = false;
        BraveLocalAIEnabled = false;
        BraveNewsDisabled = true;
        BraveTalkDisabled = true;
        BravePlaylistEnabled = false;
        BraveWaybackMachineEnabled = false;
        EmailAliasesEnabled = false;

        # Telemetry.
        BraveP3AEnabled = false;
        BraveStatsPingEnabled = false;
        BraveWebDiscoveryEnabled = false;
        MetricsReportingEnabled = false;

        # keepassxc owns credentials and identity data.
        PasswordManagerEnabled = false;
        AutofillCreditCardEnabled = false;
        AutofillAddressEnabled = false;

        # WebRTC must not enumerate tailnet or LAN addresses.
        WebRtcIPHandling = "default_public_interface_only";

        # 5 = open the new tab page on startup.
        RestoreOnStartup = 5;
        DefaultBrowserSettingEnabled = false;
      };

      system.nssDatabases.hosts = mkForce [
        "mdns4_minimal [NOTFOUND=return]"
        "resolve [!UNAVAIL=return]"
        "files"
        "myhostname"
        "dns"
      ];
    };
}
