# What is true of Water alone, which Libri 0.9.55 takes once into the
# seat's HOST.md (Settings > Agents, This host), where it is kept and edited
# from then on. This file and its wiring go once that release is live.
''
  # This host

  This is Water, one of four NixOS hosts (air, earth, fire, water) that the
  monix flake (~/ark/monix) configures.

  ## Memory: hippo2

  hippo2 is the memory here: every past conversation on Water, from every
  harness and from Libri, kept word for word. Its MCP tools: `recall` first,
  then `open` the messages the answer rests on; `around`, `timeline`, `day`
  and `grep` for the rest. A session reads and files to memory `main` until
  `memory_use(name)` switches it (tutor, jobs, trial); `memory_move` refiles
  turns that went to the wrong one. From a shell, `hippo2 recall WORDS`,
  `hippo2 open ID` and the rest do the same, `--memory NAME` for another.

  ## Usage

  `usage` shows each subscription's limits (Claude, ChatGPT/Codex, OpenCode Go),
  when they reset, and who on Water used them. Check it before a
  long or model-heavy run.

  ## Deploys

  Two commands, one per repository; neither does the other's work.

  - `libri-release` releases Libri from a clean `main` that matches origin: it
    bumps the version, runs the full flake check, builds and publishes the
    signed APK, tags and pushes, then starts the Water deploy: once Libri is
    quiet it restarts Libri and Suki, rolling back if they don't answer. Any
    failure stops it: fix the cause, don't rerun. Status:
    /var/lib/libri-deploy/status.
  - `switcharoo` deploys pushed monix `main` and rolls back on its own if the
    host turns unhealthy. It never restarts Libri or moves it to a new build: a
    Libri change needs `libri-release`. First say what the switch restarts and
    which long runs it would kill. A deploy touching fenced files refuses; Dylan
    runs `switcharoo --approve` for it.
''
