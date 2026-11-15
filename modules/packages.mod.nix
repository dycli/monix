# Packages that carry no configuration; anything with config has its own file.
# On NixOS the system list reaches every user; a Darwin host may be shared, so
# there it goes to the primary user's profile only. The home lists are bundle
# members.
{ self, lib, ... }:
let
  tools =
    pkgs:
    let
      inherit (lib.lists) optional;
      linux = pkgs.stdenv.hostPlatform.isLinux;
    in
    [
      # neovim is absent: NvChad's wrapper provides it per-user and a plain
      # install collides.
      pkgs.vim

      pkgs.eza
      pkgs.fd
      pkgs.fzf
      pkgs.jujutsu
      pkgs.microfetch
      pkgs.nushell
      pkgs.ripgrep
      pkgs.tmux
      pkgs.tree

      # NETWORK
      pkgs.dig
    ]
    ++ optional linux pkgs.traceroute
    ++ [
      pkgs.wget
      pkgs.rsync
    ]
    ++ optional linux pkgs.strace
    ++ [
      # ARCHIVES
      pkgs.p7zip
      pkgs.unzip
      pkgs.zip

      # Also in the home concern; rebuilds need git in root's PATH.
      # Minimal build: the perl/python porcelain is dead weight fleet-wide.
      pkgs.gitMinimal
    ];
in
{
  flake.nixosModules.default = self.nixosModules.packages;
  flake.nixosModules.packages =
    { pkgs, ... }:
    {
      # nvim exists only in the primary user's profile, so a system-wide
      # EDITOR=nvim would dangle for root and service users.
      environment.variables.EDITOR = "vim";

      # nano's own module enables it independently of defaultPackages.
      environment.defaultPackages = [ ];
      programs.nano.enable = false;

      environment.systemPackages = tools pkgs;
    };

  flake.darwinModules.default = self.darwinModules.packages-darwin;
  flake.darwinModules.packages-darwin =
    { config, pkgs, ... }:
    {
      home-manager.users.${config.primaryUser}.home.packages = tools pkgs;
    };

  # DISCORD
  # macOS takes Discord's own signed app as a cask, as home.mod.nix explains.
  flake.darwinModules.desktop = self.darwinModules.packages-desktop-darwin;
  flake.darwinModules.packages-desktop-darwin =
    { lib, ... }:
    {
      homebrew.casks = lib.lists.singleton "discord";
    };

  # GRAPHICAL SESSION UTILITIES AND APPLICATIONS
  # Linux only: the elected apps and the Wayland session's tools.
  flake.nixosModules.desktop = {
    imports = lib.lists.singleton self.nixosModules.packages-desktop-linux;
    # Each unfree name travels with the bundle that installs the package.
    unfreePackages = [
      "discord"
      "discord-unwrapped"
      "obsidian"
      "spotify"
    ];
  };
  flake.homeModules.packages-desktop-linux =
    { config, pkgs, ... }:
    {
      home.packages = [
        pkgs.discord

        # Elected applications (default-apps.mod.nix); referencing the options
        # installs whatever a host overrides them to.
        config.desktopApps.email.package
        config.desktopApps.pdfViewer.package
        config.desktopApps.imageViewer.package
        config.desktopApps.videoPlayer.package
        config.desktopApps.browser.package
        config.desktopApps.passwordManager.package
        config.desktopApps.messenger.package

        pkgs.amdgpu_top
        pkgs.brightnessctl
        pkgs.cliphist
        pkgs.hyprpicker
        pkgs.hyprshot
        pkgs.libqalculate
        pkgs.pavucontrol
        pkgs.playerctl
        pkgs.wl-clip-persist
        pkgs.wl-clipboard

        pkgs.kdePackages.dolphin
        # ark is Dolphin's archive context menu; nothing else installs an icon
        # theme.
        pkgs.kdePackages.ark
        pkgs.kdePackages.breeze-icons
        pkgs.libreoffice
        pkgs.obsidian
        pkgs.element-desktop
        (pkgs.spotify.override { deviceScaleFactor = 2; })
      ];
    };

  # AUTHORING AND BUILD TOOLS
  flake.homeModules.dev = self.homeModules.packages-dev-extras;
  flake.homeModules.packages-dev-extras =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.antigravity-cli
        pkgs.muse-code
        pkgs.cargo
        pkgs.claude-code
        pkgs.clippy
        pkgs.codex
        pkgs.gcc
        pkgs.opencode
        pkgs.omp
        pkgs.pi
        pkgs.hugo
        # The codex plugin's hooks invoke node directly.
        pkgs.nodejs
        pkgs.nixd
        pkgs.rust-analyzer
        pkgs.rustc
        pkgs.rustfmt
      ];
    };
}
