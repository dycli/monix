# water's credential store: secret declarations and the role options that
# consume them. Host-side because the ciphertext is encrypted to this host's
# key.
{ config, lib, ... }:
let
  inherit (lib.lists) singleton;
in
{
  users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.katara-password.path;


  fleetLogStream.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;

  media.sabnzbdSecretsFile = config.secrets.sabnzbd-secrets.path;

  shipCameras.envFile = config.secrets.frigate-env.path;

  shipProxy.acmeTokenFile = config.secrets.cloudflare-dns-token.path;

  matrix.registrationTokenEnvFile = config.secrets.matrix-registration-env.path;
  matrix.tunnelTokenFile = config.secrets.matrix-cloudflare-tunnel-token.path;

  sokka = {
    credentialsEnvFile = config.secrets.matrix-sokka-env.path;
    registrationEnvFile = config.secrets.matrix-registration-env.path;
    claudeTokenFile = config.secrets.agent-claude-token.path;
    calendarCredentialsFile = config.secrets.sokka-caldav-json.path;
    mailCredentialsFile = config.secrets.sokka-mail-json.path;
    mailServer = "imap.migadu.com";
  };

  agentFleet.credentials = {
    claudeTokenFile = config.secrets.agent-claude-token.path;
    codexAuthFile = config.secrets.agent-codex-auth.path;
    opencodeKeyFile = config.secrets.opencode-key.path;
  };

  secrets = {
    katara-password.file = ./secrets/katara-password.age;
    agent-claude-token.file = ./secrets/agent-claude-token.age;
    agent-codex-auth.file = ./secrets/agent-codex-auth.age;
    matrix-registration-env.file = ./secrets/matrix-registration.env.age;
    matrix-sokka-env.file = ./secrets/matrix-sokka.env.age;
    sokka-caldav-json.file = ./secrets/sokka-caldav.json.age;
    sokka-mail-json.file = ./secrets/sokka-mail.json.age;
    matrix-cloudflare-tunnel-token.file = ./secrets/matrix-cloudflare-tunnel-token.age;
    matrix-alertbot-env.file = ./secrets/matrix-alertbot.env.age;
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
  # explicit trigger on its long-running consumer; oneshots need none.
  systemd.services.matrix-tunnel.restartTriggers = singleton ./secrets/matrix-cloudflare-tunnel-token.age;
  systemd.services.sabnzbd.restartTriggers = singleton ./secrets/sabnzbd-secrets.ini.age;
  systemd.services.tuwunel.restartTriggers = singleton ./secrets/matrix-registration.env.age;
  systemd.services.sokka.restartTriggers = [
    ./secrets/matrix-sokka.env.age
    ./secrets/sokka-caldav.json.age
    ./secrets/sokka-mail.json.age
  ];
  systemd.services.fleet-log-stream.restartTriggers = singleton ./secrets/matrix-alertbot.env.age;
  systemd.services.frigate.restartTriggers = singleton ./secrets/frigate.env.age;
  systemd.services.go2rtc.restartTriggers = singleton ./secrets/frigate.env.age;
}
