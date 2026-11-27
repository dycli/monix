# The agent CLIs come from numtide's llm-agents, which tracks upstream daily,
# so the CLIs, the harnesses Libri runs and the desktop apps
# (agent-desktops.mod.nix) move together on one `nix flake update llm-agents`.
{ self, inputs, ... }:
{
  flake.commonModules.default = self.commonModules.agent-clis;
  flake.commonModules.agent-clis =
    { lib, ... }:
    {
      nixpkgs.overlays = lib.lists.singleton (
        final: _:
        let
          agents = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system};
        in
        {
          inherit (agents)
            antigravity-cli
            claude-code
            codex
            dsh
            muse-code
            omp
            pi
            ;
          # llm-agents keeps OpenCode 1.x as `opencode`; 2.x is `opencode2`.
          opencode = agents.opencode2;
        }
      );
    };
}
