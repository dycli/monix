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
in
{
  "hosts/earth/dylan-password.age".publicKeys = [ earth ] ++ admin;

  "hosts/air/ang-password.age".publicKeys = [ air ] ++ admin;

  "hosts/fire/zuko-password.age".publicKeys = [ fire ] ++ admin;

  # Paid font, encrypted to every desktop host that ships it.
  "assets/fonts/comic-code.age".publicKeys = [
    earth
    fire
  ]
  ++ admin;

  "hosts/water/secrets/max-password.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/agent-claude-token.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/agent-codex-auth.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/agent-openrouter-key.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/openrouter-management-key.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/matrix-registration.env.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/matrix-cloudflare-tunnel-token.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/matrix-remy.env.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/remy-caldav.json.age".publicKeys = [ water ] ++ admin;
  "hosts/water/secrets/matrix-alertbot.env.age".publicKeys = [ water ] ++ admin;
  # DISCORD_TOKEN=...
  "hosts/water/secrets/curtisbot.env.age".publicKeys = [ water ] ++ admin;
  # INI merged over the declarative config at unit start.
  "hosts/water/secrets/sabnzbd-secrets.ini.age".publicKeys = [ water ] ++ admin;
  # CLOUDFLARE_DNS_API_TOKEN=..., Zone→DNS→Edit on su.is, for DNS-01.
  "hosts/water/secrets/cloudflare-dns-token.env.age".publicKeys = [ water ] ++ admin;
  # FRIGATE_RTSP_PASSWORD=...
  "hosts/water/secrets/frigate.env.age".publicKeys = [ water ] ++ admin;
}
