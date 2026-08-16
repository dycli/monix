# The local inference catalog and the agent lab that consumes it. Role wiring
# only; credentials and model weights stay with the importing host.
{ self, ... }:
{
  flake.nixosModules.inference-backend =
    { ... }:
    {
      imports = [ self.nixosModules.inference ];

      # llama.cpp (Vulkan) behind llama-swap on :8091, loaded on demand.
      inference.models."qwen3.6-35b-a3b" = {
        file = "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf";
        flags = [
          "--flash-attn"
          "on"
          "--jinja"
        ];
      };
      # MTP speculative decoding: the MTP tensors are embedded in the main
      # GGUF, so --spec-type selects that path with no separate draft model.
      # -np > 1 is unsupported with MTP.
      inference.models."qwen3.8-27b" = {
        file = "Qwen3.8-27B-Q6_K.gguf";
        flags = [
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
      };
    };

  flake.nixosModules.lab =
    { lib, ... }:
    let
      inherit (lib.lists) singleton;
    in
    {
      imports = [ self.nixosModules.inference-backend ];

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

      fleetLogStream.inviteUsers = singleton "@dylan:chat.su.is";

      # Baked in as memo's default so nothing sets MEMORY_DIR at runtime.
      memo.memoryDir = "/home/bridge/cockpit/memory/log";

      # Water's unified-memory GPU can map a large system-RAM GTT, and its
      # fleet guests reach inference over the private bridge.
      inference.gttSizeMiB = 98304;
      inference.extraAllowedSubnets = [ "10.100.0.0/24" ];
    };
}
