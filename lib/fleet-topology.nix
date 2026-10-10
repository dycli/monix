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

  # Unprivileged system user that owns the dispatch queue. The seat reaches
  # the queue only by running `fleet` as this user via a scoped sudo rule:
  # this account, not any agent permission list, is the dispatch security
  # boundary.
  operator = "fleet-operator";

  # Per-task limits, shared by the `fleet` tool, the drainers and the guests.
  limits = {
    # Seconds without a guest heartbeat before a task is stalled and killed.
    stallTimeout = 120;
    # Seconds an idle warm VM lives before it is rebooted preventively.
    warmMaxAge = 7200;
    # Absolute seconds a task may run, regardless of progress.
    taskTimeout = 21600;
    # Bytes in one live task exchange before the task is stopped.
    taskExchangeMaxBytes = 805306368;
    # Bytes of compressed context capsule accepted for one task.
    taskContextMaxBytes = 536870912;
  };

  bridge = "br-agents";
  hostAddr = "10.100.0.1";
  tasksDir = "/var/lib/agents/tasks";
  readersGroup = "agent-fleet-readers";

  # Carries the task exchange across virtiofs; the gid is pinned so host
  # and guest agree on it.
  guestGroup = "agent-guest";
  guestGid = 3000;

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
