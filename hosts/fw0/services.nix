{ config, lib, ... }:
{
  users.mutableUsers = false;
  users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.max-password.path;

  # tmux over tailnet SSH and opencode web at ai.su.is.
  cockpit.enable = true;

  # Resolve via the router rather than the tailnet's global nameservers,
  # so the server does not inherit the ad-block resolver's outages or
  # false positives. Merges with the aspect's --ssh.
  services.tailscale.extraSetFlags = [ "--accept-dns=false" ];

  # Host-only bridge, egress proxy and microvm.nix runner.
  agentFleet.enable = true;

  # Unit failures and the 6-hourly sweep post to the alerts room.
  alerts.enable = true;
  alerts.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;

  # Fleet audit log, streamed line for line into its own room.
  fleetLogStream.enable = true;
  fleetLogStream.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;
  fleetLogStream.inviteUsers = [ "@dylan:chat.su.is" ];

  # The store is mutable state under the seat's home, created once by
  # hand; baked in as memo's default so nothing sets MEMORY_DIR at runtime.
  memo.enable = true;
  memo.memoryDir = "/home/bridge/cockpit/memory/log";

  # Summary line atop failure alerts; falls back to the raw alert.
  alerts.summary.enable = true;
  # EcoFlow RIVER 3 Plus over USB HID (usbhid-ups, 3746:ffff).
  alerts.ups.enable = true;

  # Fabric server, tailnet-only.
  minecraft.enable = true;

  # *arr wiring is web-UI state; SABnzbd's ini is read-only.
  media.enable = true;
  media.sabnzbdSecretsFile = config.secrets.sabnzbd-secrets.path;
  # The e-reader cannot join the tailnet and pulls the OPDS feed.
  media.calibreWebLan = {
    interface = "enp191s0";
    subnet = "192.168.1.0/24";
  };

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
  shipCameras.envFile = config.secrets.frigate-env.path;

  services.immich.enable = true;

  # <service>.su.is vhosts with a wildcard DNS-01 cert.
  shipProxy.enable = true;
  shipProxy.dashboardHost = "in.su.is";
  shipProxy.acmeTokenFile = config.secrets.cloudflare-dns-token.path;

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
  # MTP speculative decoding: unsloth embeds the MTP tensors in the main
  # GGUF, so --spec-type selects the MTP path with no separate draft
  # model. n-max 2 per unsloth's llama-server guide; -np > 1 is not yet
  # supported with MTP.
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
  matrix.registrationTokenEnvFile = config.secrets.matrix-registration-env.path;
  matrix.tunnelTokenFile = config.secrets.matrix-cloudflare-tunnel-token.path;

  remy.enable = true;
  remy.credentialsEnvFile = config.secrets.matrix-remy-env.path;
  remy.registrationEnvFile = config.secrets.matrix-registration-env.path;
  remy.inviteUsers = [
    "@dylan:chat.su.is"
    "@gab:chat.su.is"
  ];
  remy.scratchpad.users = [ "@dylan:chat.su.is" ];
  remy.calendar.credentialsFile = config.secrets.remy-caldav-json.path;
  remy.model = "qwen3.6-35b-a3b";
  # Mirrors the daily log into the Syncthing vault.
  remy.famlog.path = "/home/${config.primaryUser}/crate/sync/notes/famlog.md";
  remy.famlog.owner = config.primaryUser;
  remy.famlog.group = "syncthing";

  # guildId pins slash-command sync to one server; global sync can take
  # Discord an hour.
  curtisbot.enable = true;
  curtisbot.credentialsEnvFile = config.secrets.curtisbot-env.path;
  curtisbot.guildId = "916523305362685952";
  # Same commands against a separate test.db.
  curtisbot.testGuildId = "1529484237210910753";

  # The web seat, at ai.su.is through the ship proxy.
  cockpit.webEnable = true;

  secrets = {
    max-password.file = ./secrets/max-password.age;
    agent-claude-token.file = ./secrets/agent-claude-token.age;
    agent-codex-auth.file = ./secrets/agent-codex-auth.age;
    agent-openrouter-key.file = ./secrets/agent-openrouter-key.age;
    matrix-registration-env.file = ./secrets/matrix-registration.env.age;
    matrix-remy-env.file = ./secrets/matrix-remy.env.age;
    remy-caldav-json = {
      file = ./secrets/remy-caldav.json.age;
      owner = "remy";
    };
    matrix-cloudflare-tunnel-token.file = ./secrets/matrix-cloudflare-tunnel-token.age;
    matrix-alertbot-env.file = ./secrets/matrix-alertbot.env.age;
    curtisbot-env.file = ./secrets/curtisbot.env.age;
    cloudflare-dns-token = {
      file = ./secrets/cloudflare-dns-token.env.age;
      owner = "acme";
    };
    frigate-env.file = ./secrets/frigate.env.age;
    sabnzbd-secrets = {
      file = ./secrets/sabnzbd-secrets.ini.age;
      owner = "sabnzbd";
    };
  };

  # This agenix pin has no restartUnits, so each encrypted source is an
  # explicit trigger on its long-running consumer. Oneshots re-read their
  # env every run and need none.
  systemd.services.matrix-tunnel.restartTriggers = [
    ./secrets/matrix-cloudflare-tunnel-token.age
  ];
  systemd.services.sabnzbd.restartTriggers = [ ./secrets/sabnzbd-secrets.ini.age ];
  systemd.services.tuwunel.restartTriggers = [ ./secrets/matrix-registration.env.age ];
  systemd.services.remy.restartTriggers = [ ./secrets/matrix-remy.env.age ];
  systemd.services.curtisbot.restartTriggers = [ ./secrets/curtisbot.env.age ];
  systemd.services.fleet-log-stream.restartTriggers = [ ./secrets/matrix-alertbot.env.age ];
  systemd.services.frigate.restartTriggers = [ ./secrets/frigate.env.age ];
  systemd.services.go2rtc.restartTriggers = [ ./secrets/frigate.env.age ];

  agentFleet.credentials = {
    claudeTokenFile = config.secrets.agent-claude-token.path;
    codexAuthFile = config.secrets.agent-codex-auth.path;
    openrouterKeyFile = config.secrets.agent-openrouter-key.path;
  };

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
}
