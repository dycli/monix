# ship-costs — the ledger. Estimates what this month's AI usage would have
# cost at API rates, across every pool the ship spends from:
#
#   claude      cockpit Claude Code transcripts (~/.claude/projects) +
#               fleet drone usage.json archives (tasks/done|failed)
#   chatgpt     cockpit codex sessions (~/.codex/sessions) + opencode
#               messages with providerID=openai + codex drones
#   openrouter  exact spend via the API when a key is wired (metered pool);
#               otherwise whatever opencode recorded per message
#   local       llama-swap models — counted, priced $0
#
# Token counts are real; USD figures are API-EQUIVALENT (subscriptions bill
# flat), so this is an opportunity-cost lens, not an invoice. claude.ai /
# chatgpt.com app chats leave no local artifacts and are invisible here.
#
# Pricing table lives in ship-costs-cli/src/main.rs ($/MTok) — update when
# vendors reprice.
#
# No plan-usage gauges: on-disk estimates proved unreliable. Check /usage in
# each app for real gauges.
{
  flake.nixosModules.ship-costs =
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

      cfg = config.shipCosts;

      # Helper-binary paths are baked in at build time (option_env!); the key
      # file value is a runtime path string, never a nix path literal.
      shipCosts = pkgs.rustPlatform.buildRustPackage {
        pname = "ship-costs";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./ship-costs/ship-costs-cli;
          filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
        };
        cargoLock.lockFile = ./ship-costs/ship-costs-cli/Cargo.lock;
        env = {
          SHIP_OPENROUTER_KEY_FILE = if cfg.openrouterKeyFile != null then cfg.openrouterKeyFile else "";
          SHIP_SQLITE3 = "${pkgs.sqlite.bin}/bin/sqlite3";
          SHIP_CURL = "${pkgs.curl}/bin/curl";
        };
        meta.mainProgram = "ship-costs";
      };
    in
    {
      options.shipCosts = {
        enable = mkEnableOption "the ship-costs usage/cost ledger CLI";

        openrouterKeyFile = mkOption {
          # types.str, NOT types.path: interpolating a path literal would
          # copy the key into the world-readable Nix store. Only runtime
          # paths (/run/agenix/...) belong here.
          type = types.nullOr types.str;
          default = null;
          description = ''
            Runtime path (e.g. /run/agenix/...) to a file containing an
            OpenRouter key (a management key from Settings → Management
            Keys is preferred; read-only, free) for exact per-model spend
            via the activity API. Must be readable by whoever runs
            ship-costs; never a Nix path literal. null = skip the section.
          '';
        };
      };

      config = mkIf cfg.enable {
        environment.systemPackages = [ shipCosts ];
      };
    };
}
