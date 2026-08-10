# The agent lab, part of the lab bundle: cockpit seat, worker fleet and local
# inference. Role wiring only; credentials stay with the importing host.
{
  flake.nixosModules.lab =
    { lib, ... }:
    {
      # tmux over tailnet SSH, opencode web at ai.su.is.
      cockpit.enable = true;
      cockpit.webEnable = true;

      # Host-only bridge, egress proxy and microvm.nix runner.
      agentFleet.enable = true;

      # More workers than typical demand, so a task finds an already-warm VM.
      agentFleet.workers = lib.lists.imap1 (index: name: { inherit name index; }) [
        "astrapia"
        "cicinnurus"
        "drepanornis"
        "epimachus"
        "lophorina"
        "manucodia"
        "paradisaea"
        "seleucidis"
      ];

      fleetLogStream.enable = true;
      fleetLogStream.inviteUsers = [ "@dylan:chat.su.is" ];

      # Baked in as memo's default so nothing sets MEMORY_DIR at runtime.
      memo.enable = true;
      memo.memoryDir = "/home/bridge/cockpit/memory/log";

      # llama.cpp (Vulkan) behind llama-swap on :8091, loaded on demand.
      inference.enable = true;
      inference.models."qwen3.6-35b-a3b" = {
        file = "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf";
        flags = [
          "-c"
          "65536"
          "--flash-attn"
          "on"
          "--jinja"
        ];
        aliases = [ "qwen3.6" ];
      };
      # MTP speculative decoding: the MTP tensors are embedded in the main
      # GGUF, so --spec-type selects that path with no separate draft model.
      # -np > 1 is unsupported with MTP.
      inference.models."qwen3.6-27b" = {
        file = "Qwen3.6-27B-Q6_K.gguf";
        flags = [
          "-c"
          "65536"
          "--flash-attn"
          "on"
          "--jinja"
          "--spec-type"
          "draft-mtp"
          "--spec-draft-n-max"
          "2"
          "-np"
          "1"
        ];
        aliases = [ "qwen3.6-dense" ];
      };
    };
}
