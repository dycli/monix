{
  # The AI seat's account. The uid is fixed because its network fence is a
  # drop-in on user-<uid>.slice.
  seat = {
    user = "bridge";
    uid = 1001;
    home = "/home/bridge";
    # Root writes the seat's agent transcripts here and never deletes; the
    # seat reads them through its group.
    transcripts = "/srv/storage/transcripts";
    # hippo, the seat's episodic memory.
    hippo = "/srv/storage/hippo";
  };

  hostTailnetAddr = "100.102.113.74";
  tailnetDomain = "olm-hen.ts.net";
  hostMagicDnsName = "water.olm-hen.ts.net";
  # The desktops whose visible Brave the seat drives, as Playwright MCP over
  # HTTP at this port (browser.mod.nix); each admits the seat's host alone.
  browserPort = 8932;
  desktops = {
    earth = "100.100.89.17";
    fire = "100.110.237.123";
  };

  # Address the seat dials llama-swap on; llama-swap binds the wildcard, so
  # no listener of its own is needed here.
  seatInferenceAddr = "127.0.1.12";
}
