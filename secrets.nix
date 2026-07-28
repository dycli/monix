# agenix rules. Read by the `agenix`/`ragenix` CLI (NOT imported by the flake).
#
# Each entry maps a secret file path (relative to the repo root) to the set of
# public keys it is encrypted to. A host's secrets are encrypted to that host's
# key plus every admin key, so an admin can always rekey them.
#
# To create or edit a secret:    agenix -e hosts/fw0/secrets/frigate.env.age
# To rekey everything after a
# key change:                    agenix -r
#
# Add a line here for every new secret before creating it.
let
  keys = import ./keys.nix;

  inherit (keys) admin;
  inherit (keys.hosts) fw0 fw3;
in
{
  "hosts/fw3/dylan-password.age".publicKeys = [ fw3 ] ++ admin;

  # Comic Code (paid font; see modules/desktop/fonts.mod.nix). Encrypted to
  # every desktop host that should ship it — rekey (`agenix -r`) after adding
  # a host here.
  "assets/fonts/comic-code.age".publicKeys = [ fw3 ] ++ admin;

  "hosts/fw0/secrets/max-password.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/agent-claude-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/agent-codex-auth.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/agent-openrouter-key.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/openrouter-management-key.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-registration.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-cloudflare-tunnel-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-remy.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/remy-caldav.json.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-alertbot.env.age".publicKeys = [ fw0 ] ++ admin;
  # Discord bot token for Curtis, the work orders/requests bot (DISCORD_TOKEN=...).
  "hosts/fw0/secrets/curtisbot.env.age".publicKeys = [ fw0 ] ++ admin;
  # SABnzbd confidential settings (INI: api_key/nzb_key + Usenet provider
  # credentials), merged over the declarative config at unit start.
  "hosts/fw0/secrets/sabnzbd-secrets.ini.age".publicKeys = [ fw0 ] ++ admin;
  # Cloudflare API token (Zone→DNS→Edit on su.is) for the ship-proxy
  # wildcard cert's DNS-01 (CLOUDFLARE_DNS_API_TOKEN=...).
  "hosts/fw0/secrets/cloudflare-dns-token.env.age".publicKeys = [ fw0 ] ++ admin;
  # Camera credentials for Frigate/go2rtc (FRIGATE_RTSP_PASSWORD=..., used
  # by both camera brands).
  "hosts/fw0/secrets/frigate.env.age".publicKeys = [ fw0 ] ++ admin;
}
