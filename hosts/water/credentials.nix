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
  endgrain.tunnelTokenFile = config.secrets.endgrain-cloudflare-tunnel-token.path;

  gitMirror.tokenFile = config.secrets.git-mirror-token.path;

  binaryCache.signKeyFile = config.secrets.binary-cache-key.path;

  money.keysFile = config.secrets.plaid-env.path;
  money.environment = "production";

  frame = {
    immichKeyFile = config.secrets.frame-immich-key.path;
    album = "frame";
    calendarCredentialsFile = config.secrets.frame-caldav-json.path;
    # Portsmouth, NH.
    weather = "43.07,-70.76";
  };

  # Parallel's search and fetch, as Libri's web tools call its MCP server. The
  # same key would open Parallel's paid Task and FindAll APIs; the proxy refuses them.
  keyProxy.routes.parallel = {
    host = "search.parallel.ai";
    secret = "parallel-key";
    allow = singleton "POST /mcp";
  };

  # Exa's search and page contents only; the same key opens its paid Answer
  # and Research APIs, which the proxy refuses.
  keyProxy.routes.exa = {
    host = "api.exa.ai";
    secret = "exa-key";
    header = "x-api-key";
    prefix = "";
    allow = [
      "POST /search"
      "POST /contents"
    ];
  };

  # Brave's web search only; a query string follows the path.
  keyProxy.routes.brave = {
    host = "api.search.brave.com";
    secret = "brave-search-key";
    header = "X-Subscription-Token";
    prefix = "";
    allow = singleton "~^GET /res/v1/web/search([?]|$)";
  };

  secrets = {
    binary-cache-key.file = ./secrets/binary-cache-key.age;
    katara-password.file = ./secrets/katara-password.age;
    matrix-registration-env.file = ./secrets/matrix-registration.env.age;
    agent-claude-token.file = ./secrets/agent-claude-token.age;
    suki-claude-key.file = ./secrets/suki-claude-key.age;
    suki-home-token.file = ./secrets/suki-home-token.age;
    matrix-cloudflare-tunnel-token.file = ./secrets/matrix-cloudflare-tunnel-token.age;
    immich-cloudflare-tunnel-token.file = ./secrets/immich-cloudflare-tunnel-token.age;
    endgrain-cloudflare-tunnel-token.file = ./secrets/endgrain-cloudflare-tunnel-token.age;
    cloudflare-dns-token = {
      file = ./secrets/cloudflare-dns-token.env.age;
      owner = "acme";
    };
    frigate-env.file = ./secrets/frigate.env.age;
    git-mirror-token.file = ./secrets/git-mirror-token.age;
    frame-immich-key.file = ./secrets/frame-immich-key.age;
    frame-caldav-json.file = ./secrets/frame-caldav.json.age;
    plaid-env.file = ./secrets/plaid.env.age;
    # Web search API keys, bare and root's. Libri reaches each through the key proxy.
    parallel-key.file = ./secrets/parallel-key.age;
    exa-key.file = ./secrets/exa-key.age;
    brave-search-key.file = ./secrets/brave-search-key.age;
    sabnzbd-secrets = {
      file = ./secrets/sabnzbd-secrets.ini.age;
      owner = "sabnzbd";
    };
  };

  # This agenix pin has no restartUnits, so each encrypted source is an
  # explicit trigger on its long-running consumer; oneshots need none.
  systemd.services.matrix-tunnel.restartTriggers = singleton ./secrets/matrix-cloudflare-tunnel-token.age;
  systemd.services.immich-tunnel.restartTriggers = singleton ./secrets/immich-cloudflare-tunnel-token.age;
  systemd.services.endgrain-tunnel.restartTriggers = singleton ./secrets/endgrain-cloudflare-tunnel-token.age;
  systemd.services.frame.restartTriggers = [
    ./secrets/frame-immich-key.age
    ./secrets/frame-caldav.json.age
  ];
  systemd.services.money.restartTriggers = singleton ./secrets/plaid.env.age;
  systemd.services.sabnzbd.restartTriggers = singleton ./secrets/sabnzbd-secrets.ini.age;
  systemd.services.tuwunel.restartTriggers = singleton ./secrets/matrix-registration.env.age;
  systemd.services.libri = {
    environment = {
      LIBRI_SEARCH_SOCKET = "/run/key-proxy/parallel.sock";
      LIBRI_EXA_SOCKET = "/run/key-proxy/exa.sock";
      LIBRI_BRAVE_SOCKET = "/run/key-proxy/brave.sock";
    };
  };
  systemd.services.frigate.restartTriggers = singleton ./secrets/frigate.env.age;
  systemd.services.go2rtc.restartTriggers = singleton ./secrets/frigate.env.age;
}
