# One OpenCode credential for Zen and Go on every host with an OpenCode
# client. The key enters auth.json at activation, never the Nix store.
{ self, ... }:
{
  flake.nixosModules.dev = self.nixosModules.opencode-auth;
  flake.homeModules.dev = self.homeModules.opencode-auth;

  flake.nixosModules.opencode-auth =
    { config, lib, ... }:
    {
      # Every user whose home imports the auth aspect joins this group.
      users.groups.opencode-auth = { };
      users.users.${config.primaryUser}.extraGroups = lib.lists.singleton "opencode-auth";

      secrets.opencode-key = {
        file = ../../secrets/opencode-key.age;
        group = "opencode-auth";
        mode = "0440";
      };
    };

  flake.homeModules.opencode-auth =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.meta) getExe;

      installAuth = pkgs.writeShellApplication {
        name = "install-opencode-auth";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        text = ''
          auth_dir="$HOME/.local/share/opencode"
          auth_file="$auth_dir/auth.json"
          mkdir -p "$auth_dir"
          if [ ! -e "$auth_file" ]; then
            printf '{}\n' > "$auth_file"
            chmod 600 "$auth_file"
          fi

          tmp=$(mktemp "$auth_dir/.auth.json.XXXXXX")
          trap 'rm -f "$tmp"' EXIT
          jq --exit-status --rawfile key ${osConfig.secrets.opencode-key.path} '
            ($key | gsub("[\r\n]+$"; "")) as $key
            | if ($key | length) == 0 or ($key | test("[\r\n]")) then
                error("OpenCode key must be exactly one non-empty line")
              else
                . + {
                  "opencode": { "type": "api", "key": $key },
                  "opencode-go": { "type": "api", "key": $key }
                }
              end
          ' "$auth_file" > "$tmp"
          chmod 600 "$tmp"
          mv "$tmp" "$auth_file"
          trap - EXIT
        '';
      };
    in
    {
      home.activation.opencodeAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${getExe installAuth}
      '';
    };
}
