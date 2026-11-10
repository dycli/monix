# What is true of Water alone, which Libri 0.9.55 takes once into the
# seat's HOST.md (Settings > Agents, This host), where it is kept and edited
# from then on. This file and its wiring go once that release is live.
''
  # This host

  This is Water, one of four NixOS hosts (air, earth, fire, water) that the
  monix flake (~/ark/monix) configures.

  ## Memory: hippo

  hippo is the memory here, shared with the sessions it records. From a shell,
  `hippo zoom <id> <n>`, `hippo zoom <agent>` and `hippo search <regex>` do what
  memory_zoom, agent_chat and memory_search do.

  ## Usage

  `usage` shows each subscription's limits (Claude, ChatGPT/Codex, OpenCode Go),
  when they reset, and who on Water used them. Check it before a long or
  model-heavy run.

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
