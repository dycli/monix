# Desktop clients for coding agents, kept to compare Libri against. Taken from
# numtide's llm-agents, which tracks upstream daily; nixpkgs lags on T3 Code
# and Paseo and lacks Claude Desktop and ChatGPT (which carries Codex).
{ inputs, ... }:
{
  flake.homeModules.agent-desktops =
    { pkgs, ... }:
    let
      agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      home.packages = [
        agents.paseo-desktop
        agents.t3code
        agents.claude-desktop
        agents.chatgpt
        agents.opencode2-desktop
      ];
    };
}
