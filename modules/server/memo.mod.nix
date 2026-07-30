# memo — an append-only LOG.txt of one-line memories plus a TREE/ of
# summaries; `memo wake` prints a fixed-size digest weighted to recency.
# The tool hands compression prompts to the agent rather than summarizing
# itself.
#
# The store is mutable state, not managed by Nix, with its default path
# baked in at build time. It is never auto-created: making it is a
# deliberate one-time step (mkdir plus `memo import`).
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
          # MEMORY_DIR still overrides this at runtime.
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
