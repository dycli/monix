# A visible, persistent Brave session on each desktop, exposed to the Water
# cockpit only through an MCP process carried over the existing Tailscale SSH
# channel. The remote process imports the active UWSM environment so it opens
# on the real desktop rather than growing a second display stack.
{ self, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.agent-browser;
  flake.nixosModules.agent-browser =
    { lib, pkgs, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;

      # The nixpkgs MCP wrapper retains every bundled Playwright browser.
      # Brave is already the elected browser, so keep only the JS library and
      # remove the wrapper that references that redundant browser closure.
      playwrightLibrary = pkgs.playwright-test.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          rm -rf "$out/bin"
        '';
      });

      playwrightMcp = pkgs.playwright-mcp.overrideAttrs {
        postInstall = ''
          pkg_dir="$out/lib/node_modules/@playwright/mcp"
          rm -rf "$pkg_dir/node_modules/playwright"
          rm -rf "$pkg_dir/node_modules/playwright-core"
          ln -s ${playwrightLibrary}/lib/node_modules/playwright "$pkg_dir/node_modules/playwright"
          ln -s ${playwrightLibrary}/lib/node_modules/playwright-core "$pkg_dir/node_modules/playwright-core"
        '';
      };

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

          exec ${getExe playwrightMcp} \
            --executable-path ${getExe pkgs.brave} \
            --user-data-dir "$profile" \
            --output-dir "$output" \
            --sandbox
        '';
      };
    in
    {
      environment.systemPackages = singleton browserMcp;
    };
}
