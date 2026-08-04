# agenix rules. Read by the `agenix`/`ragenix` CLI (NOT imported by the flake).
#
# Each entry maps a secret file path (relative to the repo root) to the set of
# public keys it is encrypted to. A host's secrets are encrypted to that host's
# key plus every admin key, so an admin can always rekey them.
#
# To create or edit a secret:    agenix -e hosts/water/secrets/frigate.env.age
# To rekey everything after a
# key change:                    agenix -r
#
# Add a line here for every new secret before creating it.
let
  keys = import ./keys.nix;

  inherit (keys) admin;
  inherit (keys.hosts) water earth;
in
{
  "hosts/earth/dylan-password.age".publicKeys = [ earth ] ++ admin;

  # Comic Code (paid font; see modules/desktop/fonts.mod.nix). Encrypted to
  # every desktop host that should ship it — rekey (`agenix -r`) after adding
  # a host here.
  "assets/fonts/comic-code.age".publicKeys = [ earth ] ++ admin;

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
  # Discord bot token for Curtis, the work orders/requests bot (DISCORD_TOKEN=...).
  "hosts/water/secrets/curtisbot.env.age".publicKeys = [ water ] ++ admin;
  # SABnzbd confidential settings (INI: api_key/nzb_key + Usenet provider
  # credentials), merged over the declarative config at unit start.
  "hosts/water/secrets/sabnzbd-secrets.ini.age".publicKeys = [ water ] ++ admin;
  # Cloudflare API token (Zone→DNS→Edit on su.is) for the ship-proxy
  # wildcard cert's DNS-01 (CLOUDFLARE_DNS_API_TOKEN=...).
  "hosts/water/secrets/cloudflare-dns-token.env.age".publicKeys = [ water ] ++ admin;
  # Camera credentials for Frigate/go2rtc (FRIGATE_RTSP_PASSWORD=..., used
  # by both camera brands).
  "hosts/water/secrets/frigate.env.age".publicKeys = [ water ] ++ admin;
}
