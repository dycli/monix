# The ai bundle: the agent cluster — cockpit seat, worker fleet and
# local inference. Shares water with the homelab role today; a dedicated
# machine would import this (plus dev) and water would drop it.
#
# Only role wiring lives here; credentials stay with the importing host
# (see homelab.mod.nix's header).
{
  flake.nixosModules.ai =
    { lib, ... }:
    {
      # The seat: tmux over tailnet SSH, opencode web at ai.su.is.
      cockpit.enable = true;
      cockpit.webEnable = true;

      # Host-only bridge, egress proxy and microvm.nix runner.
      agentFleet.enable = true;

      # More workers than typical demand, so tasks get an already-warm VM.
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

      # Fleet audit log, streamed line for line into its own room (the
      # homeserver defaults to the loopback tuwunel from the homelab role).
      fleetLogStream.enable = true;
      fleetLogStream.inviteUsers = [ "@dylan:chat.su.is" ];

      # The store is mutable state under the seat's home, created once by
      # hand; baked in as memo's default so nothing sets MEMORY_DIR at
      # runtime.
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
      # MTP speculative decoding: unsloth embeds the MTP tensors in the
      # main GGUF, so --spec-type selects the MTP path with no separate
      # draft model. n-max 2 per unsloth's llama-server guide; -np > 1 is
      # not yet supported with MTP.
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
