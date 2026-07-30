{ config, lib, ... }:
{
  users.mutableUsers = false;
  users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.max-password.path;

  # Primary interactive agent cockpit: tmux over tailnet SSH and opencode
  # web at ai.su.is, both tailnet-only.
  cockpit.enable = true;

  # Infrastructure resolves locally (router DNS), not through the
  # tailnet's global nameservers: the Mullvad ad-block resolver is for
  # interactive devices, and a server shouldn't inherit its outages or
  # filter false-positives (merges with the aspect's --ssh).
  services.tailscale.extraSetFlags = [ "--accept-dns=false" ];

  # Agent-fleet microVM host: host-only bridge + egress proxy + microvm.nix
  # runner (microvm-host.mod.nix).
  agentFleet.enable = true;

  # Unit failures and the 6-hourly sweep post to the Ship Alerts room.
  alerts.enable = true;
  alerts.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;

  # Agent-fleet audit log streamed line-for-line into a Fleet Ops room.
  fleetLogStream.enable = true;
  fleetLogStream.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;
  fleetLogStream.inviteUsers = [ "@dylan:chat.su.is" ];

  # Append-only memory CLI; the store is mutable state under the SEAT's
  # ~/cockpit/memory, created once by hand. Baked in as memo's default so
  # nothing has to set MEMORY_DIR at runtime.
  memo.enable = true;
  memo.memoryDir = "/home/bridge/cockpit/memory/log";

  # Plain-language line atop failure alerts, from the ship-local model
  # (degrades to the raw alert if inference is down).
  alerts.summary.enable = true;
  # EcoFlow RIVER 3 Plus over USB HID (usbhid-ups, 3746:ffff).
  alerts.ups.enable = true;

  # Fabric Minecraft server, tailnet-only and egress-fenced.
  minecraft.enable = true;

  # Jellyfin + Sonarr/Radarr/Bazarr/Prowlarr/SABnzbd, tailnet-only and
  # egress-fenced. *arr wiring is web-UI state; SABnzbd is declarative
  # (read-only ini).
  media.enable = true;
  media.sabnzbdSecretsFile = config.secrets.sabnzbd-secrets.path;
  # The Xteink X3 e-reader (ESP32, can't join the tailnet) pulls the OPDS
  # feed, so its port is additionally opened on the LAN.
  media.calibreWebLan = {
    interface = "enp191s0";
    subnet = "192.168.1.0/24";
  };

  # Smart-home backend, tailnet-only at :8123 / ha.su.is. Device wiring is
  # UI state.
  services.home-assistant.enable = true;
  homeAssistant.lanSubnets = [ "192.168.1.0/24" ];

  # Frigate NVR at frigate.su.is via the ship proxy.
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

  # Family photo library, tailnet-only at :2283, photos under /srv/photos.
  services.immich.enable = true;

  # Tailnet-only pretty names: <service>.su.is vhosts on nginx with a
  # wildcard DNS-01 cert.
  shipProxy.enable = true;
  shipProxy.dashboardHost = "in.su.is";
  shipProxy.acmeTokenFile = config.secrets.cloudflare-dns-token.path;

  # Dashboard of links to every web UI at plain http://fw0. Tailnet-only.
  services.homepage-dashboard.enable = true;

  # llama.cpp (Vulkan) behind llama-swap on :8091, tailnet-only, models
  # loaded on demand.
  inference.enable = true;
  inference.models."qwen3.6-35b-a3b" = {
    file = "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf";
    flags = [
      "-c"
      "65536"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [ "qwen3.6" ];
  };
  inference.models."gpt-oss-120b" = {
    file = "gpt-oss-120b-mxfp4-00001-of-00003.gguf";
    flags = [
      "-c"
      "131072"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [ "gpt-oss" ];
  };
  # Dense small models for judgment-heavy chat (remy); better instruction
  # following/routing than the 3B-active MoE. Mistral is remy's brain;
  # Qwen 27B is on the bench for an A/B via remy.model.
  inference.models."mistral-small-3.2-24b" = {
    file = "Mistral-Small-3.2-24B-Instruct-2506-UD-Q4_K_XL.gguf";
    flags = [
      "-c"
      "32768"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [
      "mistral"
      "mistral-small"
    ];
  };
  inference.models."qwen3.6-27b" = {
    file = "Qwen3.6-27B-UD-Q4_K_XL.gguf";
    flags = [
      "-c"
      "65536"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [ "qwen3.6-dense" ];
  };

  # Serves the declaratively managed ~/crate/sync mesh.
  services.syncthing.enable = true;

  # tuwunel without federation, token-gated registration, exposed at
  # chat.su.is through its own tunnel.
  matrix.enable = true;
  matrix.serverName = "chat.su.is";
  matrix.registrationTokenEnvFile = config.secrets.matrix-registration-env.path;
  matrix.tunnelTokenFile = config.secrets.matrix-cloudflare-tunnel-token.path;

  # Household organizer.
  remy.enable = true;
  remy.credentialsEnvFile = config.secrets.matrix-remy-env.path;
  remy.registrationEnvFile = config.secrets.matrix-registration-env.path;
  remy.inviteUsers = [
    "@dylan:chat.su.is"
    "@gab:chat.su.is"
  ];
  remy.scratchpad.users = [ "@dylan:chat.su.is" ];
  remy.calendar.credentialsFile = config.secrets.remy-caldav-json.path;
  # Dense 24B: sharper instruction following/routing than the qwen a3b MoE.
  # Flip to "qwen3.6-27b" or "qwen3.6-35b-a3b" to A/B.
  remy.model = "mistral-small-3.2-24b";
  # Mirror the daily log into the Syncthing/Obsidian vault.
  remy.famlog.path = "/home/${config.primaryUser}/crate/sync/notes/famlog.md";
  remy.famlog.owner = config.primaryUser;
  remy.famlog.group = "syncthing";

  # Curtis, the work-Discord bot: staff requests (wholesale commands parked).
  # guildId pins slash-command sync to one server for instant availability
  # (global sync can take Discord up to an hour).
  curtisbot.enable = true;
  curtisbot.credentialsEnvFile = config.secrets.curtisbot-env.path;
  curtisbot.guildId = "916523305362685952";
  # Test server sandbox: same commands, separate test.db.
  curtisbot.testGuildId = "1529484237210910753";

  # opencode web UI cockpit seat, tailnet-only at ai.su.is via the ship
  # proxy (grey-cloud A record → fw0's tailnet IP).
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

  # agenix in this input has no restartUnits option; make each encrypted
  # source an explicit trigger on its long-running consumer so secret
  # rotation restarts the daemon (oneshots re-read their env every run and
  # need none of this).
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

  # Keep more workers than typical demand so incoming tasks get an already
  # warm VM instead of waiting for boot.
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
