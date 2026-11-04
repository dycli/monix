# Desktop clients for coding agents, kept to compare Libri against. Taken from
# numtide's llm-agents, which tracks upstream daily; nixpkgs lags on T3 Code
# and Paseo and lacks Claude Desktop and ChatGPT (which carries Codex).
{ inputs, ... }:
{
  flake.homeModules.agent-desktops =
    { pkgs, ... }:
    {
      home.packages = with inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}; [
        paseo-desktop
        t3code
        claude-desktop
        chatgpt
        opencode2-desktop
      ];
    };
}
