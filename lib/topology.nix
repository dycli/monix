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
    # hippo2, the memory daemon: one SQLite file per memory.
    hippo2 = "/srv/storage/hippo2";
    # The build the seat's Libri and hippo run. Each deploy moves it; a new name
    # for a change that needs monix and the build together lets a monix rollback
    # return to the build it ran with.
    libriBuild = "/var/lib/libri-build/libri";
  };
  # The assistants' household (libri.mod.nix); the seat is in it too.
  household = "/var/lib/household";

  hostTailnetAddr = "100.102.113.74";
  tailnetDomain = "olm-hen.ts.net";
  hostMagicDnsName = "water.olm-hen.ts.net";

  # Address the seat dials llama-swap on; llama-swap binds the wildcard, so
  # no listener of its own is needed here.
  seatInferenceAddr = "127.0.1.12";
}
