# Hammerspoon: global keys that open apps, on Option with the letters the
# Hyprland session puts on Super (hyprland/keybinds.mod.nix). macOS keeps its
# own window handling.
{ self, ... }:
{
  flake.darwinModules.desktop = self.darwinModules.hammerspoon;
  flake.darwinModules.hammerspoon =
    { config, lib, ... }:
    {
      # The cask keeps one path across updates, so the Accessibility grant
      # holds; a Nix store path would move with every update.
      homebrew.casks = lib.lists.singleton "hammerspoon";

      # A switch swaps the symlink in ~/.hammerspoon, which the pathwatcher
      # sees, so Hammerspoon reloads without the switch reaching the app.
      # autoLaunch is the login item in this account alone; a launchd agent
      # would need the user's GUI session at switch time.
      home-manager.users.${config.primaryUser}.home.file.".hammerspoon/init.lua".text = ''
        hs.autoLaunch(true)

        configWatcher = hs.pathwatcher.new(hs.configdir, hs.reload):start()

        -- GUI apps start with launchd's bare PATH; a login shell finds the
        -- user's profile.
        local function inGhostty(program)
          return function()
            hs.task.new("/usr/bin/open", nil, {
              "-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lc", "exec " .. program,
            }):start()
          end
        end

        local function focus(app)
          return function() hs.application.launchOrFocus(app) end
        end

        -- KEEP AWAKE
        -- The cup shows while the display is kept from idle sleep; clicking
        -- it ends that. The state lives in the app, so a reload reads it back.
        local cup = nil
        local toggleAwake

        local function showAwake(on)
          if on and not cup then
            cup = hs.menubar.new()
            cup:setTitle("☕")
            cup:setTooltip("Keeping the display awake")
            cup:setClickCallback(function() toggleAwake() end)
          elseif not on and cup then
            cup:delete()
            cup = nil
          end
        end

        toggleAwake = function()
          showAwake(hs.caffeinate.toggle("displayIdle"))
        end

        showAwake(hs.caffeinate.get("displayIdle"))

        -- KEYS
        local option = { "alt" }
        hs.hotkey.bind(option, "return", focus("Ghostty"))
        hs.hotkey.bind(option, "w", focus("Brave Browser"))
        hs.hotkey.bind(option, "r", inGhostty("lf"))
        hs.hotkey.bind(option, "n", inGhostty("nvim"))
        hs.hotkey.bind(option, "f", focus("Finder"))
        hs.hotkey.bind(option, "escape", hs.caffeinate.lockScreen)
        -- kill() asks the app to quit, so its own save prompts still run.
        hs.hotkey.bind(option, "q", function()
          local app = hs.application.frontmostApplication()
          if app then app:kill() end
        end)
        hs.hotkey.bind(option, "i", toggleAwake)
      '';
    };
}
