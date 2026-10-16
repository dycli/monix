# water's credential store: secret declarations and the role options that
# consume them. Host-side because the ciphertext is encrypted to this host's
# key.
{ config, lib, ... }:
let
  inherit (lib.lists) singleton;
in
{
  users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.katara-password.path;

  media.sabnzbdSecretsFile = config.secrets.sabnzbd-secrets.path;

  shipCameras.envFile = config.secrets.frigate-env.path;

  shipProxy.acmeTokenFile = config.secrets.cloudflare-dns-token.path;

  matrix.registrationTokenEnvFile = config.secrets.matrix-registration-env.path;
  matrix.tunnelTokenFile = config.secrets.matrix-cloudflare-tunnel-token.path;
  immich.tunnelTokenFile = config.secrets.immich-cloudflare-tunnel-token.path;

  gitMirror.tokenFile = config.secrets.git-mirror-token.path;

  frame = {
    immichKeyFile = config.secrets.frame-immich-key.path;
    album = "frame";
  };

  yeoman = {
    instances.sokka = {
      credentialsEnvFile = config.secrets.matrix-sokka-env.path;
      web = true;
      mailCredentialsFile = config.secrets.sokka-mail-json.path;
    };
    instances.suki = {
      credentialsEnvFile = config.secrets.matrix-suki-env.path;
      web = true;
      mailCredentialsFile = config.secrets.suki-mail-json.path;
      claudeKeyFile = config.secrets.suki-claude-key.path;
    };
    registrationEnvFile = config.secrets.matrix-registration-env.path;
    claudeTokenFile = config.secrets.agent-claude-token.path;
    calendarCredentialsFile = config.secrets.yeoman-caldav-json.path;
    homeTokenFile = config.secrets.yeoman-home-token.path;
    requestsKeyFile = config.secrets.yeoman-requests-key.path;
    mailServer = "imap.migadu.com";
  };

  secrets = {
    katara-password.file = ./secrets/katara-password.age;
    agent-claude-token.file = ./secrets/agent-claude-token.age;
    matrix-registration-env.file = ./secrets/matrix-registration.env.age;
    matrix-sokka-env.file = ./secrets/matrix-sokka.env.age;
    matrix-suki-env.file = ./secrets/matrix-suki.env.age;
    yeoman-caldav-json.file = ./secrets/yeoman-caldav.json.age;
    sokka-mail-json.file = ./secrets/sokka-mail.json.age;
    suki-mail-json.file = ./secrets/suki-mail.json.age;
    suki-claude-key.file = ./secrets/suki-claude-key.age;
    yeoman-home-token.file = ./secrets/yeoman-home-token.age;
    yeoman-requests-key.file = ./secrets/yeoman-requests-key.age;
    matrix-cloudflare-tunnel-token.file = ./secrets/matrix-cloudflare-tunnel-token.age;
    immich-cloudflare-tunnel-token.file = ./secrets/immich-cloudflare-tunnel-token.age;
    cloudflare-dns-token = {
      file = ./secrets/cloudflare-dns-token.env.age;
      owner = "acme";
    };
    frigate-env.file = ./secrets/frigate.env.age;
    git-mirror-token.file = ./secrets/git-mirror-token.age;
    frame-immich-key.file = ./secrets/frame-immich-key.age;
    sabnzbd-secrets = {
      file = ./secrets/sabnzbd-secrets.ini.age;
      owner = "sabnzbd";
    };
  };

  # This agenix pin has no restartUnits, so each encrypted source is an
  # explicit trigger on its long-running consumer; oneshots need none.
  systemd.services.matrix-tunnel.restartTriggers = singleton ./secrets/matrix-cloudflare-tunnel-token.age;
  systemd.services.immich-tunnel.restartTriggers = singleton ./secrets/immich-cloudflare-tunnel-token.age;
  systemd.services.frame.restartTriggers = singleton ./secrets/frame-immich-key.age;
  systemd.services.sabnzbd.restartTriggers = singleton ./secrets/sabnzbd-secrets.ini.age;
  systemd.services.tuwunel.restartTriggers = singleton ./secrets/matrix-registration.env.age;
  systemd.services.sokka.restartTriggers = [
    ./secrets/matrix-sokka.env.age
    ./secrets/yeoman-caldav.json.age
    ./secrets/sokka-mail.json.age
    ./secrets/yeoman-home-token.age
    ./secrets/yeoman-requests-key.age
  ];
  systemd.services.suki.restartTriggers = [
    ./secrets/matrix-suki.env.age
    ./secrets/suki-mail.json.age
    ./secrets/yeoman-caldav.json.age
    ./secrets/yeoman-home-token.age
    ./secrets/yeoman-requests-key.age
  ];
  systemd.services.frigate.restartTriggers = singleton ./secrets/frigate.env.age;
  systemd.services.go2rtc.restartTriggers = singleton ./secrets/frigate.env.age;
}
