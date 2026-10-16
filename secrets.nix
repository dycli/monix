# agenix rules: secret path to the public keys it is encrypted to. Read by the
# agenix CLI, not imported by the flake. Host secrets carry that host's key
# plus every admin key, so an admin can always rekey.
let
  keys = import ./keys.nix;

  inherit (keys) admin;
  inherit (keys.hosts)
    water
    earth
    fire
    air
    ;

  # Not imported by the flake, so nixpkgs lib.lists.singleton is unavailable
  # here; this is the same one-element-list constructor under a local name.
  singleton = x: [ x ];
in
{
  "hosts/earth/dylan-password.age".publicKeys = singleton earth ++ admin;

  "hosts/air/aang-password.age".publicKeys = singleton air ++ admin;

  "hosts/fire/zuko-password.age".publicKeys = singleton fire ++ admin;

  # Paid font, encrypted to every desktop host that ships it.
  "assets/fonts/comic-code.age".publicKeys = [
    water
    earth
    fire
  ]
  ++ admin;

  "hosts/water/secrets/katara-password.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/agent-claude-token.age".publicKeys = singleton water ++ admin;
  "secrets/opencode-key.age".publicKeys = [
    water
    fire
    earth
  ]
  ++ admin;
  "hosts/water/secrets/matrix-registration.env.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/matrix-cloudflare-tunnel-token.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/immich-cloudflare-tunnel-token.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/hippo-door-passphrase.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/sokka-door-passphrase.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/suki-door-passphrase.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/hippo-cloudflare-tunnel-token.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/matrix-sokka.env.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/matrix-suki.env.age".publicKeys = singleton water ++ admin;
  # Sokka's CalDAV accounts: [{"name","url","username","password"}, ...].
  "hosts/water/secrets/yeoman-caldav.json.age".publicKeys = singleton water ++ admin;
  # Sokka's IMAP accounts: [{"name","username","password"}, ...].
  "hosts/water/secrets/sokka-mail.json.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/suki-mail.json.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/suki-claude-key.age".publicKeys = singleton water ++ admin;
  # A Home Assistant long-lived access token, raw, for the assistants' home tools.
  "hosts/water/secrets/yeoman-home-token.age".publicKeys = singleton water ++ admin;
  # Parallel account API key, raw (platform.parallel.ai), for the assistants' web search.
  "hosts/water/secrets/yeoman-search-key.age".publicKeys = singleton water ++ admin;
  # Seerr's API key, raw (Settings > General), for the assistants' media requests.
  "hosts/water/secrets/yeoman-requests-key.age".publicKeys = singleton water ++ admin;
  # Databento API key, raw (db-...), for the market-data recorder.
  "hosts/water/secrets/databento-key.age".publicKeys = singleton water ++ admin;
  # INI merged over the declarative config at unit start.
  "hosts/water/secrets/sabnzbd-secrets.ini.age".publicKeys = singleton water ++ admin;
  # CLOUDFLARE_DNS_API_TOKEN=..., Zone→DNS→Edit on su.is, for DNS-01.
  "hosts/water/secrets/cloudflare-dns-token.env.age".publicKeys = singleton water ++ admin;
  # Cloudflare account token, raw, "Read all resources", for the seat's Cloudflare MCP.
  "hosts/water/secrets/cloudflare-read-token.age".publicKeys = singleton water ++ admin;
  # FRIGATE_RTSP_PASSWORD=...
  "hosts/water/secrets/frigate.env.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/git-mirror-token.age".publicKeys = singleton water ++ admin;
}
