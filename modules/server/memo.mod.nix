# memo — the engineer's autobiographical memory (a behavior-identical Rust
# port of VictorTaelin/OptMem). One append-only LOG.txt of one-line memories
# plus a TREE/ of LLM-written summaries; `memo wake` prints a fixed-size
# digest whose detail is proportional to recency. The tool never summarizes:
# it hands compression prompts to the agent and bookkeeps the results.
#
# The store (MEMORY_DIR) is mutable state under the cockpit, NOT managed by
# Nix; the default path is baked into the binary at build time so no session
# env plumbing is needed. The directory is never auto-created — making it is
# creating the identity, a deliberate one-time act (mkdir + memo import).
#
# House rules live in fleet-guide.nix, not here: only the cockpit engineer
# runs memo; drones and subagents never do.
{
  flake.nixosModules.memo =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib.strings) hasSuffix;
      inherit (lib) types;

      cfg = config.memo;

      memo = pkgs.rustPlatform.buildRustPackage {
        pname = "memo";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./memo/memo-cli;
          filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
        };
        cargoLock.lockFile = ./memo/memo-cli/Cargo.lock;
        env = {
          # Compile-time default store; the MEMORY_DIR env var still wins,
          # so tests and one-off stores keep the upstream contract.
          MEMO_MEMORY_DIR = cfg.memoryDir;
        };
        meta.mainProgram = "memo";
      };
    in
    {
      options.memo = {
        enable = mkEnableOption "the memo append-only agent memory CLI";

        memoryDir = mkOption {
          type = types.str;
          description = ''
            Default MEMORY_DIR baked into the binary: the directory holding
            LOG.txt and TREE/. A runtime MEMORY_DIR env var overrides it.
            The directory must be created by hand once (identity creation).
          '';
        };
      };

      config = mkIf cfg.enable {
        environment.systemPackages = [ memo ];
      };
    };
}
