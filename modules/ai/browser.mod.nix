# Two Brave MCP servers for the AI seat. kestrel-browser-mcp drives a visible,
# persistent Brave session on a desktop, reached over the existing Tailscale
# SSH channel; it imports the active UWSM environment so it opens on the real
# desktop rather than growing a second display stack. kestrel-browser-headless
# runs a throwaway headless Brave as the caller, so the seat browses from
# inside its own internet-only fence with no desktop needed.
{ self, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.agent-browser;
  flake.nixosModules.agent-browser =
    { lib, pkgs, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.strings) concatStringsSep;

      playwrightMcp = import ./playwright-mcp.nix pkgs;

      playwrightArgs = [
        "--browser chrome"
        "--executable-path ${getExe pkgs.brave}"
        "--sandbox"
      ];

      browserMcp = pkgs.writeShellApplication {
        name = "kestrel-browser-mcp";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.systemd
        ];
        text = ''
          runtime_dir=/run/user/$(id -u)
          export XDG_RUNTIME_DIR="$runtime_dir"
          export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus"

          systemctl --user is-active --quiet graphical-session.target || {
            echo "no active graphical session on $(hostname)" >&2
            exit 1
          }

          while IFS= read -r assignment; do
            case "$assignment" in
              DISPLAY=*|WAYLAND_DISPLAY=*|XDG_CURRENT_DESKTOP=*|XDG_SESSION_TYPE=*|OZONE_PLATFORM=*|ELECTRON_OZONE_PLATFORM_HINT=*)
                export "''${assignment?}"
                ;;
            esac
          done < <(systemctl --user show-environment)

          profile="$HOME/.local/share/kestrel-browser"
          output="$HOME/Downloads/Kestrel"
          install -d -m 0700 "$profile" "$output"

          exec ${getExe playwrightMcp} ${concatStringsSep " " playwrightArgs} \
            --user-data-dir "$profile" \
            --output-dir "$output"
        '';
      };

      headlessMcp = pkgs.writeShellApplication {
        name = "kestrel-browser-headless";
        runtimeInputs = singleton pkgs.coreutils;
        text = ''
          output="$HOME/Downloads/Kestrel"
          install -d -m 0700 "$output"

          exec ${getExe playwrightMcp} ${concatStringsSep " " playwrightArgs} \
            --headless \
            --isolated \
            --output-dir "$output"
        '';
      };
    in
    {
      environment.systemPackages = [
        browserMcp
        headlessMcp
      ];
    };
}
