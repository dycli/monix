# Brave policies every desktop shares: Linux writes them as managed JSON,
# macOS as a configuration profile (brave.mod.nix).
{
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
}
