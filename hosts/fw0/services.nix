{ config, lib, ... }:
{
  users.mutableUsers = false;
  users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.max-password.path;

  # Primary interactive agent cockpit: tmux over tailnet SSH and opencode
  # web through Cloudflare Access.
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

  # Append-only memory CLI; the store is mutable state under
  # ~/cockpit/memory, created once by hand.
  memo.enable = true;
  memo.memoryDir = "/home/${config.primaryUser}/cockpit/memory/log";

  # Usage/cost ledger CLI. OpenRouter section bootstrap-gated until its
  # read-only management key is provisioned.
  shipCosts.enable = true;
  shipCosts.openrouterKeyFile =
    if builtins.pathExists ./secrets/openrouter-management-key.age then
      config.secrets.openrouter-management-key.path
    else
      null;

  # Plain-language line atop failure alerts, from the ship-local model
  # (degrades to the raw alert if inference is down).
  alerts.summary.enable = true;
  # EcoFlow RIVER 3 Plus over USB HID (usbhid-ups, 3746:ffff).
  alerts.ups.enable = true;

  # Fabric Minecraft server, tailnet-only and egress-fenced.
  minecraft.enable = true;

  # Jellyfin + Sonarr/Radarr/Bazarr/Prowlarr/SABnzbd, tailnet-only and
  # egress-fenced. *arr wiring is web-UI state; SABnzbd is declarative
  # (read-only ini) with credentials bootstrap-gated until the secret exists.
  media.enable = true;
  media.sabnzbdSecretsFile =
    if builtins.pathExists ./secrets/sabnzbd-secrets.ini.age then
      config.secrets.sabnzbd-secrets.path
    else
      null;
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

  # Frigate NVR, bootstrap-gated on the camera credentials secret;
  # frigate.su.is via the ship proxy.
  shipCameras.enable = builtins.pathExists ./secrets/frigate.env.age;
  shipCameras.reolink = {
    cam1 = "192.168.1.201";
    cam2 = "192.168.1.55";
  };
  shipCameras.tapo = {
    tapo1 = "192.168.1.218";
    tapo2 = "192.168.1.220";
  };
  shipCameras.lanSubnets = [ "192.168.1.0/24" ];
  shipCameras.envFile =
    if builtins.pathExists ./secrets/frigate.env.age then
      config.secrets.frigate-env.path
    else
      # Placeholder; shipCameras stays disabled until the secret exists.
      "/dev/null";

  # Family photo library, tailnet-only at :2283, photos under /srv/photos.
  services.immich.enable = true;

  # Tailnet-only pretty names: <service>.su.is vhosts on nginx with a
  # wildcard DNS-01 cert, bootstrap-gated on the Cloudflare DNS token.
  shipProxy.enable = builtins.pathExists ./secrets/cloudflare-dns-token.env.age;
  shipProxy.dashboardHost = "in.su.is";
  shipProxy.acmeTokenFile =
    if builtins.pathExists ./secrets/cloudflare-dns-token.env.age then
      config.secrets.cloudflare-dns-token.path
    else
      null;

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

  # Household organizer and budget-room assistant.
  remy.enable = true;
  remy.credentialsEnvFile = config.secrets.matrix-remy-env.path;
  remy.registrationEnvFile = config.secrets.matrix-registration-env.path;
  remy.budgetRoomId = "!pSYRAx0dRdSkbxwgPr:chat.su.is";
  remy.budgetbotEnvFile = config.secrets.matrix-budgetbot-env.path;
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
  remy.famlog.path = "/home/max/crate/sync/notes/famlog.md";
  remy.famlog.owner = "max";
  remy.famlog.group = "syncthing";

  # News digests post twice daily to the captain's private News room.
  newsbot.enable = true;
  newsbot.credentialsEnvFile = config.secrets.matrix-newsbot-env.path;
  newsbot.registrationEnvFile = config.secrets.matrix-registration-env.path;
  newsbot.claudeTokenFile = config.secrets.agent-claude-token.path;
  newsbot.inviteUsers = [ "@dylan:chat.su.is" ];

  # Curtis, the work-Discord bot: wholesale order lines + staff requests.
  # guildId pins slash-command sync to one server for instant availability
  # (global sync can take Discord up to an hour).
  curtisbot.enable = true;
  curtisbot.credentialsEnvFile = config.secrets.curtisbot-env.path;
  curtisbot.guildId = "916523305362685952";
  # Test server sandbox: same commands, separate test.db.
  curtisbot.testGuildId = "1529484237210910753";

  # opencode web UI cockpit seat, authenticated by Cloudflare Access.
  cockpit.webEnable = true;
  systemd.services.opencode-web.serviceConfig.Environment = [
    "OPENCODE_CONFIG=/home/max/.config/opencode/opencode.jsonc"
  ];
  cockpit.webTunnelTokenFile = config.secrets.opencode-web-cloudflare-tunnel-token.path;

  secrets = {
    max-password.file = ./secrets/max-password.age;
    agent-claude-token.file = ./secrets/agent-claude-token.age;
    agent-codex-auth.file = ./secrets/agent-codex-auth.age;
    agent-openrouter-key.file = ./secrets/agent-openrouter-key.age;
    opencode-web-cloudflare-tunnel-token.file = ./secrets/opencode-web-cloudflare-tunnel-token.age;
    matrix-registration-env.file = ./secrets/matrix-registration.env.age;

    # Retained for remy's adopt-budget-room oneshot.
    matrix-budgetbot-env.file = ./secrets/matrix-budgetbot.env.age;
    matrix-remy-env.file = ./secrets/matrix-remy.env.age;
    matrix-newsbot-env.file = ./secrets/matrix-newsbot.env.age;
    remy-caldav-json = {
      file = ./secrets/remy-caldav.json.age;
      owner = "remy";
    };
    matrix-cloudflare-tunnel-token.file = ./secrets/matrix-cloudflare-tunnel-token.age;
    matrix-alertbot-env.file = ./secrets/matrix-alertbot.env.age;
    curtisbot-env.file = ./secrets/curtisbot.env.age;
  }
  // lib.optionalAttrs (builtins.pathExists ./secrets/openrouter-management-key.age) {
    openrouter-management-key = {
      file = ./secrets/openrouter-management-key.age;
      owner = config.primaryUser;
    };
  }
  // lib.optionalAttrs (builtins.pathExists ./secrets/cloudflare-dns-token.env.age) {
    cloudflare-dns-token = {
      file = ./secrets/cloudflare-dns-token.env.age;
      owner = "acme";
    };
  }
  // lib.optionalAttrs (builtins.pathExists ./secrets/frigate.env.age) {
    frigate-env.file = ./secrets/frigate.env.age;
  }
  // lib.optionalAttrs (builtins.pathExists ./secrets/sabnzbd-secrets.ini.age) {
    sabnzbd-secrets = {
      file = ./secrets/sabnzbd-secrets.ini.age;
      owner = "sabnzbd";
    };
  };

  # agenix in this input has no restartUnits option; make the encrypted
  # source an explicit unit trigger so token rotation restarts cloudflared.
  systemd.services.opencode-web-tunnel.restartTriggers = [
    ./secrets/opencode-web-cloudflare-tunnel-token.age
  ];
  systemd.services.matrix-tunnel.restartTriggers = [
    ./secrets/matrix-cloudflare-tunnel-token.age
  ];
  systemd.services.sabnzbd.restartTriggers =
    lib.lists.optionals (builtins.pathExists ./secrets/sabnzbd-secrets.ini.age) [
      ./secrets/sabnzbd-secrets.ini.age
    ];

  agentFleet.credentials = {
    claudeTokenFile = config.secrets.agent-claude-token.path;
    codexAuthFile = config.secrets.agent-codex-auth.path;
    openrouterKeyFile = config.secrets.agent-openrouter-key.path;
  };

  # Keep more workers than typical demand so incoming tasks get an already
  # warm VM instead of waiting for boot. Fleet-wide resources are slice-capped.
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
