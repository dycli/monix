# The homelab bundle: the ship's whole service role — media automation,
# family apps, AI stack, agent fleet and the cockpit seat — as one
# importable unit, so the role can move to a new machine by importing
# this bundle there.
#
# Only role wiring lives here. Credentials stay with the host that owns
# them: every `*File` option below the enables references
# `config.secrets.*`, which the importing host must declare (agenix
# ciphertext is encrypted to one host's key and cannot travel). Hardware
# facts (UPS sensor, NIC-bound LAN exposure) stay in the host file too.
{ self, ... }:
{
  flake.nixosModules.homelab = self.nixosModules.homelab-role;
  flake.nixosModules.homelab-role =
    { config, lib, ... }:
    {
      # tmux over tailnet SSH and opencode web at ai.su.is.
      cockpit.enable = true;
      # The web seat, at ai.su.is through the ship proxy.
      cockpit.webEnable = true;

      # Servers reach sshd over the tailnet only, since tailscale0 is a
      # trusted interface; port 22 never opens publicly.
      services.openssh.openFirewall = lib.modules.mkDefault false;

      # Resolve via the router rather than the tailnet's global
      # nameservers, so the role does not inherit the ad-block resolver's
      # outages or false positives. Merges with the aspect's --ssh.
      services.tailscale.extraSetFlags = [ "--accept-dns=false" ];

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

      # Unit failures and the 6-hourly sweep post to the alerts room.
      alerts.enable = true;
      # Summary line atop failure alerts; falls back to the raw alert.
      alerts.summary.enable = true;

      # Fleet audit log, streamed line for line into its own room.
      fleetLogStream.enable = true;
      fleetLogStream.inviteUsers = [ "@dylan:chat.su.is" ];

      # The store is mutable state under the seat's home, created once by
      # hand; baked in as memo's default so nothing sets MEMORY_DIR at
      # runtime.
      memo.enable = true;
      memo.memoryDir = "/home/bridge/cockpit/memory/log";

      # Fabric server, tailnet-only.
      minecraft.enable = true;

      # *arr wiring is web-UI state; SABnzbd's ini is read-only.
      media.enable = true;

      # Device wiring is UI state.
      services.home-assistant.enable = true;
      homeAssistant.lanSubnets = [ "192.168.1.0/24" ];

      shipCameras.enable = true;
      shipCameras.reolink = {
        cam1 = "192.168.1.201";
        cam2 = "192.168.1.55";
      };
      shipCameras.tapo = {
        tapo1 = "192.168.1.218";
        tapo2 = "192.168.1.220";
      };
      shipCameras.lanSubnets = [ "192.168.1.0/24" ];

      services.immich.enable = true;

      # <service>.su.is vhosts with a wildcard DNS-01 cert.
      shipProxy.enable = true;
      shipProxy.dashboardHost = "in.su.is";

      # Links to every web UI, at plain http://fw0.
      services.homepage-dashboard.enable = true;

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

      services.syncthing.enable = true;

      # Exposed at chat.su.is through its own tunnel.
      matrix.enable = true;
      matrix.serverName = "chat.su.is";

      remy.enable = true;
      remy.inviteUsers = [
        "@dylan:chat.su.is"
        "@gab:chat.su.is"
      ];
      remy.scratchpad.users = [ "@dylan:chat.su.is" ];
      remy.model = "qwen3.6-35b-a3b";
      # Mirrors the daily log into the Syncthing vault.
      remy.famlog.path = "/home/${config.primaryUser}/crate/sync/notes/famlog.md";
      remy.famlog.owner = config.primaryUser;
      remy.famlog.group = "syncthing";

      # guildId pins slash-command sync to one server; global sync can
      # take Discord an hour.
      curtisbot.enable = true;
      curtisbot.guildId = "916523305362685952";
      # Same commands against a separate test.db.
      curtisbot.testGuildId = "1529484237210910753";
    };
}
