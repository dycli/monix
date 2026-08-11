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
    earth
    fire
  ]
  ++ admin;

  "hosts/water/secrets/max-password.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/agent-claude-token.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/agent-codex-auth.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/agent-openrouter-key.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/matrix-registration.env.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/matrix-cloudflare-tunnel-token.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/matrix-remy.env.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/remy-caldav.json.age".publicKeys = singleton water ++ admin;
  "hosts/water/secrets/matrix-alertbot.env.age".publicKeys = singleton water ++ admin;
  # DISCORD_TOKEN=...
  "hosts/water/secrets/curtisbot.env.age".publicKeys = singleton water ++ admin;
  # INI merged over the declarative config at unit start.
  "hosts/water/secrets/sabnzbd-secrets.ini.age".publicKeys = singleton water ++ admin;
  # CLOUDFLARE_DNS_API_TOKEN=..., Zone→DNS→Edit on su.is, for DNS-01.
  "hosts/water/secrets/cloudflare-dns-token.env.age".publicKeys = singleton water ++ admin;
  # FRIGATE_RTSP_PASSWORD=...
  "hosts/water/secrets/frigate.env.age".publicKeys = singleton water ++ admin;
}
