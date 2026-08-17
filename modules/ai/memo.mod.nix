# memo: an append-only LOG.txt of one-line memories plus a TREE/ of
# summaries. The store is mutable state, never auto-created.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.memo;
  flake.nixosModules.memo =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.options) mkOption;
      inherit (lib) types;

      cfg = config.memo;

      memo = pkgs.rustPlatform.buildRustPackage {
        pname = "memo";
        version = "0.1.0";
        src = ./memo/memo-cli;
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
        memoryDir = mkOption {
          type = types.str;
          description = ''
            Default MEMORY_DIR baked into the binary: the directory holding
            LOG.txt and TREE/. A runtime MEMORY_DIR env var overrides it.
            The directory must be created once with memo init (identity creation).
          '';
        };
      };

      config = {
        environment.systemPackages = singleton memo;
      };
    };
}
